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
# 本脚本不靠猜：把几种可能的换算方式各试一遍（运维显式给的 > 自省本容器
# Mounts > 恒等映射），每一种都【真起一个探针容器去看标记文件在不在】，
# 第一个实测通过的才采用。全都不通过就 probe 失败，绝不带着错误的映射启动。
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

# 候选映射来源之一：自省本容器的 Mounts（挂了宿主 socket 的兄弟模式）
introspected_map() {
  local cid line n=0
  cid=$(own_container_id) || return 1
  while read -r line; do
    [ -n "$line" ] || continue
    echo "$line"; n=$((n + 1))
  done < <("$DOCKER_BIN" inspect "$cid" \
             --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null || true)
  [ "$n" -gt 0 ]
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

# 当前 PATHMAP 对不对？真起一个容器去看标记文件在不在——这是唯一可信的判据。
probe_map() {
  local hp marker rc=0
  hp=$(to_host_path "$DSH_ROOT") || return 1
  marker=".pathmap-probe.$$"
  : > "$DSH_ROOT/$marker" 2>/dev/null || { log "$DSH_ROOT 不可写，无法校验路径映射"; return 1; }
  "$DOCKER_BIN" run --rm --network none --entrypoint /bin/sh \
      -v "$hp:/probe:ro" "$DSH_IMAGE" -c "test -e /probe/$marker" >/dev/null 2>&1 || rc=$?
  rm -f "$DSH_ROOT/$marker"
  return "$rc"
}

cache_key() { printf '%s|%s|%s' "$DSH_IMAGE" "$DSH_ROOT" "${DSH_HOST_ROOT:-}" | cksum | tr -d ' \n'; }

load_pathmap_cache() {
  [ -r "$PATHMAP_CACHE" ] || return 1
  local key line first=1
  PATHMAP=()
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then key="$line"; first=0; continue; fi
    [ -n "$line" ] && PATHMAP+=("$line")
  done < "$PATHMAP_CACHE"
  [ "${key:-}" = "$(cache_key)" ] && [ ${#PATHMAP[@]} -gt 0 ]
}

save_pathmap_cache() {
  mkdir -p "$(dirname "$PATHMAP_CACHE")" 2>/dev/null || return 0
  { cache_key; printf '%s\n' "${PATHMAP[@]}"; } > "$PATHMAP_CACHE" 2>/dev/null || true
}

# 逐个候选试，第一个【实测通过】的采用。
#
# 候选顺序有讲究：
#   1 DSH_HOST_ROOT —— 运维显式给的，最权威
#   2 自省本容器 Mounts —— 兄弟模式（挂了宿主 socket）的正解
#   3 恒等映射 —— 我们本来就在宿主上，或者容器内自己跑了 dockerd（DinD）。
#     DinD 那种情况自省一定失败（内层守护进程不认识外层容器），早先直接
#     报 NO_PATHMAP 就把这条路堵死了——其实它的路径本来就是同构的。
# 每个候选都要过 probe_map 那一关，所以「猜」不会变成「蒙着眼睛挂」。
resolve_pathmap() {
  if load_pathmap_cache; then return 0; fi

  local -a tried=()
  local desc

  if [ -n "${DSH_HOST_ROOT:-}" ]; then
    PATHMAP=("$DSH_ROOT|$DSH_HOST_ROOT"); desc="DSH_HOST_ROOT=$DSH_HOST_ROOT"
    if probe_map; then log "路径映射: $desc（实测通过）"; save_pathmap_cache; return 0; fi
    tried+=("$desc")
  fi

  if in_container; then
    local -a m=()
    local line
    while read -r line; do m+=("$line"); done < <(introspected_map || true)
    if [ ${#m[@]} -gt 0 ]; then
      PATHMAP=("${m[@]}"); desc="自省本容器 Mounts（${#m[@]} 条）"
      if probe_map; then log "路径映射: $desc（实测通过）"; save_pathmap_cache; return 0; fi
      tried+=("$desc")
    else
      tried+=("自省本容器 Mounts（拿不到，可能是容器内自跑的 dockerd）")
    fi
  fi

  PATHMAP=("/|/"); desc="恒等映射（宿主直跑或 DinD）"
  if probe_map; then log "路径映射: $desc（实测通过）"; save_pathmap_cache; return 0; fi
  tried+=("$desc")

  PATHMAP=()
  log "所有候选的路径映射都没通过实测——挂进容器的目录里看不到标记文件。"
  log "  已试过:"; printf '    - %s\n' "${tried[@]}" >&2
  log "  多半是数据目录只存在于本容器的可写层里，宿主上没有对应路径，"
  log "  兄弟容器物理上挂不到它。处理办法二选一："
  log "    a) 重起主容器时把数据目录 bind mount 进来（-v /宿主某处:$DSH_ROOT）"
  log "    b) 已知宿主路径的话直接给: DSH_HOST_ROOT=<宿主上的绝对路径>"
  return 1
}

container_name() { echo "$DSH_CONTAINER_PREFIX-$1"; }

# 资源限额不是哪里都给得了：DinD、rootless、cgroup 控制器没下放的环境里，
# --memory / --cpus / --pids-limit 会让 docker run 直接失败。问一下守护进程
# 到底支持哪几样，不支持的丢掉并【明说丢了什么】——静默降级会让人以为限额生效。
build_limit_args() {
  LIMIT_ARGS=()
  local caps dropped=""
  caps=$("$DOCKER_BIN" info --format \
    '{{.MemoryLimit}} {{.CPUCfsQuota}} {{.PidsLimit}}' 2>/dev/null) || caps=""
  local mem cpu pids
  read -r mem cpu pids <<< "${caps:-false false false}"
  if [ "$mem" = "true" ]; then LIMIT_ARGS+=(--memory "$DSH_CONTAINER_MEMORY")
  else dropped="$dropped --memory"; fi
  if [ "$cpu" = "true" ]; then LIMIT_ARGS+=(--cpus "$DSH_CONTAINER_CPUS")
  else dropped="$dropped --cpus"; fi
  if [ "$pids" = "true" ]; then LIMIT_ARGS+=(--pids-limit "$DSH_CONTAINER_PIDS")
  else dropped="$dropped --pids-limit"; fi
  [ -z "$dropped" ] || log "本守护进程不支持这些限额，已跳过:$dropped（隔离本身不受影响，但一个员工可以吃光资源）"
}

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
  if ! resolve_pathmap; then
    echo "NO_PATHMAP"
    return 1
  fi
  echo "OK image=$DSH_IMAGE map=${#PATHMAP[@]}项"
  return 0
}

# ---------- run ----------
backend_run() {
  local USERNAME="${1:?缺少 username}" PORT="${2:?缺少 port}"
  local DSH_HOME_DIR="${3:?缺少 dsh_home}" WORKSPACE="${4:?缺少 workspace}"

  docker_ok || die "docker 不可用（调度器本应先 probe 过）"
  validate_run_args "$PORT" "$DSH_HOME_DIR" "$WORKSPACE" "$USERNAME"
  image_ok || die "镜像不存在: $DSH_IMAGE（scripts/build-dsh-image.sh）"
  resolve_pathmap || die "定不出可用的宿主路径映射，拒绝以错误的挂载启动实例"

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
    -p "$DSH_PUBLISH_ADDR:$PORT:$PORT"
    -w "$WORKSPACE"
    -e "DSH_INNER_PORT=$DSH_INNER_PORT"
  )

  # 一个员工跑爆资源不该拖垮所有人——但限额得守护进程支持才加得上
  build_limit_args
  args+=("${LIMIT_ARGS[@]}")

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
