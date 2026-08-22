#!/bin/bash
# =====================================================================
# 后端 container —— 每个 dsh 实例一个独立容器
#
# 用法（由 dsh-sandbox.sh 调度，不直接调用）:
#   backends/container.sh probe
#   backends/container.sh run <username> <port> <dsh_home> <workspace>
#
# 为什么这是最强的一档：
#   独立 mount ns（只挂本人的空间）+ 独立 net ns（员工之间连不到彼此的端口）
#   + 独立 pid ns + 独立 UID + cgroup 资源限额，全部由 docker 一次性给到，
#   且【不需要宿主放行非特权 user namespace】——这正是 bwrap 在容器里跑不起来
#   的那个前提。
#
# 唯一必须守住的一条：**实例容器绝不挂 docker socket**。
#   容器里能摸到 docker socket 就是一句话逃逸：
#     docker run -v /:/host alpine cat /host/etc/shadow
#   本脚本不挂 /var，也不传 DOCKER_HOST，实例容器里没有任何 docker 客户端凭据。
#
# 落地时第一个坑是 volume 路径。容器里的 docker 有两种形态：
#   sibling（挂宿主 socket，最常见）：起出来的是宿主的兄弟容器，-v 左边必须写
#     【宿主上的绝对路径】，写当前容器内的路径会挂空目录——比起不来更难查。
#   DinD（容器内自己的 dockerd）：路径就是当前容器内的路径，不用换算。
# 本脚本不靠猜：先自省本容器的 Mounts 建出映射表，再【真起一个探针容器去看
# 标记文件在不在】。验不过就 probe 失败，绝不带着错误的映射去启动实例。
# =====================================================================
set -euo pipefail

BACKEND_TAG=container
# shellcheck source=./common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DOCKER_BIN="${DSH_DOCKER_BIN:-docker}"
DSH_IMAGE="${DSH_IMAGE:-dsh-instance:local}"
DSH_CONTAINER_PREFIX="${DSH_CONTAINER_PREFIX:-dsh}"
DSH_CONTAINER_MEMORY="${DSH_CONTAINER_MEMORY:-2g}"
DSH_CONTAINER_CPUS="${DSH_CONTAINER_CPUS:-2}"
DSH_CONTAINER_PIDS="${DSH_CONTAINER_PIDS:-512}"
DSH_INNER_PORT="${DSH_INNER_PORT:-3000}"
# 端口发布到哪个地址。默认回环：nginx 连得到，员工容器之间连不到
#（各自独立 netns，容器里的 127.0.0.1 是它自己的；经网关 IP 也够不着回环）。
DSH_PUBLISH_ADDR="${DSH_PUBLISH_ADDR:-127.0.0.1}"
PATHMAP_CACHE="${DSH_PATHMAP_CACHE:-$DSH_ROOT/dsh-runtime/.pathmap-verified}"

CONTAINER_ENTRY="$DSH_ROOT/dsh-runtime/dsh-container-entry.sh"

docker_ok() {
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || return 1
  "$DOCKER_BIN" info >/dev/null 2>&1
}

image_ok() { "$DOCKER_BIN" image inspect "$DSH_IMAGE" >/dev/null 2>&1; }

# ---------- 本容器自省 ----------
# mountinfo / cgroup 里的 64 位十六进制串不一定就是本容器的 id（可能是上层
# overlay 的 layer id）。所以把候选都列出来，逐个拿 docker inspect 验，
# 第一个验得过的才算数——猜错了会挂错目录，比起不来更难查。
own_container_id() {
  local id
  for id in $( { grep -oE '[0-9a-f]{64}' /proc/self/mountinfo 2>/dev/null || true;
                 grep -oE '[0-9a-f]{64}' /proc/self/cgroup 2>/dev/null || true;
                 cat /etc/hostname 2>/dev/null || true; } | awk '!seen[$0]++' ); do
    [ -n "$id" ] || continue
    "$DOCKER_BIN" inspect "$id" >/dev/null 2>&1 && { echo "$id"; return 0; }
  done
  return 1
}

# PATHMAP[] 每项 "容器内路径|宿主路径"
PATHMAP=()
build_pathmap() {
  PATHMAP=()
  if [ -n "${DSH_HOST_ROOT:-}" ]; then
    # 运维显式给了换算基准，最可靠，优先用
    PATHMAP+=("$DSH_ROOT|$DSH_HOST_ROOT")
    return 0
  fi
  if ! in_container; then
    # 我们自己就跑在宿主上（或 DinD 场景下路径同构），恒等映射
    PATHMAP+=("/|/")
    return 0
  fi
  local cid line
  cid=$(own_container_id) || return 1
  while read -r line; do
    [ -n "$line" ] && PATHMAP+=("$line")
  done < <("$DOCKER_BIN" inspect "$cid" \
             --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null || true)
  [ ${#PATHMAP[@]} -gt 0 ]
}

# 取最长匹配前缀做换算；匹配不上就失败（绝不悄悄回落成恒等映射）
to_host_path() { # $1=容器内绝对路径
  local p="$1" best="" best_len=-1 entry dest src rest
  for entry in "${PATHMAP[@]}"; do
    dest="${entry%%|*}"
    if [ "$dest" = "/" ] || [ "$p" = "$dest" ] || [ "${p#"$dest"/}" != "$p" ]; then
      if [ ${#dest} -gt "$best_len" ]; then best_len=${#dest}; best="$entry"; fi
    fi
  done
  [ -n "$best" ] || return 1
  dest="${best%%|*}"; src="${best#*|}"
  if [ "$dest" = "/" ]; then rest="$p"; else rest="${p#"$dest"}"; fi
  echo "${src%/}$rest"
}

pathmap_fingerprint() { printf '%s\n' "$DSH_IMAGE" "${PATHMAP[@]}" | cksum | tr -d ' \n'; }

# 不靠猜：真起一个容器，看挂进去的目录里有没有那个标记文件。
verify_pathmap() {
  local fp; fp=$(pathmap_fingerprint)
  if [ -r "$PATHMAP_CACHE" ] && [ "$(cat "$PATHMAP_CACHE")" = "$fp" ]; then
    return 0
  fi
  local hp marker
  hp=$(to_host_path "$DSH_ROOT") || { log "路径映射覆盖不到 $DSH_ROOT"; return 1; }
  marker=".pathmap-probe.$$"
  : > "$DSH_ROOT/$marker"
  local rc=0
  "$DOCKER_BIN" run --rm --network none --entrypoint /bin/sh \
      -v "$hp:/probe:ro" "$DSH_IMAGE" -c "test -e /probe/$marker" >/dev/null 2>&1 || rc=$?
  rm -f "$DSH_ROOT/$marker"
  if [ "$rc" != 0 ]; then
    log "路径映射校验失败: 把 $DSH_ROOT 当作宿主上的 $hp 挂进容器，里面看不到标记文件。"
    log "  当前映射表:"; printf '    %s\n' "${PATHMAP[@]}" >&2
    log "  处理: 用 DSH_HOST_ROOT=<dsh-files 所在的宿主绝对路径> 显式指定。"
    return 1
  fi
  mkdir -p "$(dirname "$PATHMAP_CACHE")"
  echo "$fp" > "$PATHMAP_CACHE"
  return 0
}

container_name() { echo "$DSH_CONTAINER_PREFIX-$1"; }

# ---------- probe ----------
backend_probe() {
  if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    echo "MISSING docker"; log "未找到 docker 客户端"; return 1
  fi
  if ! "$DOCKER_BIN" info >/dev/null 2>&1; then
    echo "NO_DAEMON"
    log "docker 客户端在，但连不上守护进程（socket 未挂载 / 无权限）:"
    { "$DOCKER_BIN" info 2>&1 | tail -3 | sed 's/^/     /' >&2; } || true
    return 1
  fi
  if ! image_ok; then
    echo "NO_IMAGE $DSH_IMAGE"
    log "镜像 $DSH_IMAGE 不存在 -> 运行 scripts/build-dsh-image.sh 构建"
    return 1
  fi
  if [ ! -r "$CONTAINER_ENTRY" ]; then
    echo "NO_ENTRY"; log "找不到容器入口脚本: $CONTAINER_ENTRY"; return 1
  fi
  if ! build_pathmap; then
    echo "NO_PATHMAP"
    log "无法确定「容器内路径 -> 宿主路径」的换算（自省本容器 Mounts 失败）。"
    log "  处理: 设 DSH_HOST_ROOT=<$DSH_ROOT 在宿主上的绝对路径>。"
    return 1
  fi
  verify_pathmap || { echo "BAD_PATHMAP"; return 1; }
  echo "OK image=$DSH_IMAGE map=${#PATHMAP[@]}项"
  return 0
}

# ---------- run ----------
backend_run() {
  local USERNAME="${1:?缺少 username}" PORT="${2:?缺少 port}"
  local DSH_HOME_DIR="${3:?缺少 dsh_home}" WORKSPACE="${4:?缺少 workspace}"

  docker_ok || die "docker 不可用（调度器本应先 probe 过）"
  validate_run_args "$PORT" "$DSH_HOME_DIR" "$WORKSPACE"
  image_ok || die "镜像不存在: $DSH_IMAGE（scripts/build-dsh-image.sh）"
  build_pathmap || die "无法建立宿主路径映射，设 DSH_HOST_ROOT 显式指定"
  verify_pathmap || die "宿主路径映射校验不通过，拒绝以错误的挂载启动实例"

  WORKSPACE=$(readlink -f "$WORKSPACE")
  DSH_HOME_DIR=$(readlink -f "$DSH_HOME_DIR")

  local name; name=$(container_name "$USERNAME")
  # 清掉同名残留（上次非正常退出留下的），否则 docker run 会直接报名字冲突
  "$DOCKER_BIN" rm -f "$name" >/dev/null 2>&1 || true

  local uid gid
  uid=$(stat -c %u "$WORKSPACE"); gid=$(stat -c %g "$WORKSPACE")

  local args=(
    run --rm --init --name "$name"
    --user "$uid:$gid"
    # 逃逸面收干净：不给任何 capability，禁止 setuid 提权
    --cap-drop ALL --security-opt no-new-privileges
    # 一个员工跑爆资源不该拖垮所有人
    --memory "$DSH_CONTAINER_MEMORY" --cpus "$DSH_CONTAINER_CPUS"
    --pids-limit "$DSH_CONTAINER_PIDS"
    -p "$DSH_PUBLISH_ADDR:$PORT:$PORT"
    -w "$WORKSPACE"
    -e "DSH_INNER_PORT=$DSH_INNER_PORT"
  )

  local hp
  # 只读：node + dsh 本体、共享插件、容器入口脚本
  hp=$(to_host_path "$NODE_ROOT")        || die "换算不出 $NODE_ROOT 的宿主路径"
  args+=(-v "$hp:$NODE_ROOT:ro")
  hp=$(to_host_path "$CONTAINER_ENTRY")  || die "换算不出 $CONTAINER_ENTRY 的宿主路径"
  args+=(-v "$hp:/opt/dsh/entry.sh:ro")
  if [ -d "$SHARED_PROFILES" ]; then
    # 必须排在 DSH_HOME 之前？不——docker 的 -v 与挂载顺序无关，按目标路径
    # 深度自动排序，嵌套关系天然正确，不存在 bwrap 那个「后挂覆盖先挂」的坑。
    hp=$(to_host_path "$SHARED_PROFILES") || die "换算不出 $SHARED_PROFILES 的宿主路径"
    args+=(-v "$hp:$SHARED_PROFILES:ro")
  fi

  # 可写：本人实例状态 + 本人工作区
  hp=$(to_host_path "$DSH_HOME_DIR") || die "换算不出 $DSH_HOME_DIR 的宿主路径"
  args+=(-v "$hp:$DSH_HOME_DIR:rw")
  hp=$(to_host_path "$WORKSPACE")    || die "换算不出 $WORKSPACE 的宿主路径"
  args+=(-v "$hp:$WORKSPACE:rw")

  parse_extra_mounts "$WORKSPACE"
  local i
  for i in "${!MOUNT_PATHS[@]}"; do
    hp=$(to_host_path "${MOUNT_PATHS[$i]}") || die "换算不出 ${MOUNT_PATHS[$i]} 的宿主路径"
    args+=(-v "$hp:${MOUNT_PATHS[$i]}:${MOUNT_MODES[$i]}")
  done

  build_instance_env "$USERNAME" "$DSH_HOME_DIR" "$WORKSPACE" "$ALLOWED_ROOTS"
  local kv
  for kv in "${INSTANCE_ENV[@]}"; do args+=(-e "$kv"); done

  build_trusted_host_args

  # 收尾靠三件事，不再额外挂 trap（下面是 exec，trap 根本不会触发）：
  #   1 --rm：docker run 收到 SIGTERM（core.py 的 pkill）时带走容器
  #   2 --init：容器内 PID 1 是 init，能回收僵尸、正确转发信号
  #   3 上面那句 `docker rm -f`：万一被 SIGKILL 留下残骸，下次启动先清掉
  log "启动 $USERNAME: 容器 $name, 发布 $DSH_PUBLISH_ADDR:$PORT, ws=$WORKSPACE"
  # 命令行刻意保留 "<...>/dsh web --port <PORT> " 这个子串：宿主侧的
  # pgrep/pkill 与其他后端共用同一套识别方式。入口脚本会把端口改写成内部端口。
  exec "$DOCKER_BIN" "${args[@]}" "$DSH_IMAGE" \
    /bin/bash /opt/dsh/entry.sh "$NODE_BIN" "$DSH_BIN" web --port "$PORT" "${HOST_ARGS[@]}"
}

case "${1:-}" in
  probe) backend_probe ;;
  run)   shift; backend_run "$@" ;;
  *) echo "用法: $0 probe | run <username> <port> <dsh_home> <workspace>" >&2; exit 2 ;;
esac
