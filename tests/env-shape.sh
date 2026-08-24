#!/bin/bash
# =====================================================================
# 环境形状验收 —— 在【当前这个环境】里断言调度器挑对了档，且那一档真的隔离住了。
#
# 用法: tests/env-shape.sh <期望后端: container|bwrap|uid|refuse> [部署根]
#
# 这个脚本本身不关心自己跑在哪：宿主、普通容器、挂了 docker socket 的容器、
# 特权容器都可以。CI 用不同的 `docker run` 参数把它丢进不同形状里跑，
# 一次覆盖多种真实部署环境，而不是只覆盖某一台机器。
#
# SHAPE_BLOCK_USERNS=1 时，本脚本先确认这个形状里非特权 user namespace 确实
# 用不了；如果居然能用（runner 的内核开关和预期不符），就直接把 bwrap 挪走，
# 并把这件事打出来——模拟没模拟成必须写在脸上，不能让 CI 假绿。
#
# SHAPE_START_DOCKERD=1 时，先在【本容器内部】启动一个自己的 dockerd，再用它
# 构建实例镜像。这构造的是【真·嵌套】：员工容器是本容器的孩子，不是兄弟。
# 与「挂宿主 socket」那种形状的区别在于路径——嵌套下容器内外路径同构，
# 自省宿主 Mounts 必然失败（内层守护进程不认识外层容器），走的是恒等映射那条
# 候选分支。这条分支此前没有任何测试覆盖。
# =====================================================================
set -uo pipefail

EXPECT="${1:?用法: env-shape.sh <container|bwrap|uid|refuse> [部署根]}"
R="${2:-${DSH_ROOT:-/work/fakedeploy}}"
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DSH_ROOT="$R"
SANDBOX="$R/dsh-runtime/dsh-sandbox.sh"

fail() { echo "::error::$*"; echo "❌ $*"; exit 1; }
say()  { echo "--- $*"; }

say "形状自述"
echo "  期望后端 : $EXPECT"
echo "  uid      : $(id -u) ($(id -un 2>/dev/null || echo ?))"
echo "  容器内   : $([ -f /.dockerenv ] && echo 是 || echo 否)"
echo "  docker   : $(command -v docker >/dev/null 2>&1 && (docker info >/dev/null 2>&1 && echo '守护进程可达' || echo '仅客户端') || echo 无)"
echo "  bwrap    : $(command -v bwrap || echo 无)"

if [ "${SHAPE_BLOCK_USERNS:-0}" = "1" ]; then
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "  ✓ 本形状里没有 bwrap，命名空间档天然不可用"
  elif bwrap --ro-bind / / --unshare-all --share-net true 2>/dev/null; then
    echo "  ⚠ 本形状本应拦住非特权 userns，但 bwrap 居然跑得起来"
    echo "    （runner 的内核开关与预期不符）。改用 BWRAP_BIN 指向不存在的路径来"
    echo "    构造同一个输入——对调度器而言两者等价：这一档不可用。"
    export BWRAP_BIN=/nonexistent-bwrap
  else
    echo "  ✓ 非特权 userns 确实被拦住了（bwrap 跑不起来）"
  fi
fi

say "搭仿真部署树 -> $R"
"$REPO/scripts/make-fake-deploy.sh" "$R" "$REPO" || fail "建树失败"

if [ "${SHAPE_START_DOCKERD:-0}" = "1" ]; then
  say "在本容器内启动 dockerd（真·嵌套：员工容器将是本容器的孩子）"
  [ "$(id -u)" = "0" ] || fail "启动 dockerd 需要 root —— 这正是嵌套的硬前提"
  command -v dockerd >/dev/null 2>&1 || fail "本镜像里没有 dockerd"

  # cgroup v2 委派：根 cgroup 里只要还挂着进程，就处于 threaded 模式，
  # 不能把 domain 控制器交给子 cgroup，内层 dockerd 建容器时会报
  #   cannot enter cgroupv2 ... with domain controllers -- it is in threaded mode
  # 标准解法是先把根里的进程全挪进一个叶子，再把控制器下放。
  # 尽力而为：做不到就让 dockerd 自己去报错，不在这里假装成功。
  if [ -w /sys/fs/cgroup/cgroup.procs ] 2>/dev/null; then
    mkdir -p /sys/fs/cgroup/init 2>/dev/null || true
    xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    sed -e 's/ / +/g' -e 's/^/+/' < /sys/fs/cgroup/cgroup.controllers \
      > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    echo "  · cgroup 委派: subtree_control=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || echo 读不到)"
  fi

  # vfs 存储驱动：overlay-on-overlay 在很多内核上不被允许，vfs 慢但一定能用
  dockerd --storage-driver=vfs > /tmp/dockerd.log 2>&1 &
  for _ in $(seq 1 40); do docker info >/dev/null 2>&1 && break; sleep 1; done
  if ! docker info >/dev/null 2>&1; then
    echo "--- dockerd 日志尾部"; tail -40 /tmp/dockerd.log
    fail "内层 dockerd 起不来（多半是容器权限不够，需要 --privileged）"
  fi
  echo "  ✓ 内层 dockerd 就绪: $(docker info --format '{{.Name}} 存储驱动={{.Driver}}')"
  # 这里必须确认它【不是】外层的守护进程：内层的看不到任何已有容器
  echo "  · 它管着的容器数: $(docker info --format '{{.Containers}}')"

  say "用内层 dockerd 构建实例镜像"
  DSH_ROOT="$R" bash "$REPO/scripts/build-dsh-image.sh" >/tmp/build.log 2>&1 \
    || { tail -30 /tmp/build.log; fail "实例镜像构建失败"; }
  echo "  ✓ $(docker images --format '{{.Repository}}:{{.Tag}}' | head -3 | tr '\n' ' ')"
fi

say "环境能力报告"
bash "$SANDBOX" --report 2>&1 | sed 's/^/  /'

BACKEND=$(bash "$SANDBOX" --backend 2>/dev/null) || BACKEND=""
say "调度器选中: ${BACKEND:-（无）}"

if [ "$EXPECT" = "refuse" ]; then
  [ -z "$BACKEND" ] || fail "本形状本应一档都挑不出来，实际挑中了 $BACKEND"
  # fail-closed 必须体现在真实启动路径上，而不只是 --check 的返回码
  out=$(bash "$SANDBOX" zhangsan 13101 "$R/dsh-users/zhangsan" \
        "$R/dsh-files/departments/研发部/张三" 2>&1)
  rc=$?
  [ "$rc" != 0 ] || fail "挑不出后端却启动成功了，fail-closed 失效"
  echo "$out" | grep -q "拒绝启动" || fail "拒绝时没说清原因，运维无从下手：$out"
  echo "✅ 形状 refuse：如期拒绝启动，且给出了逐项原因"
  exit 0
fi

[ "$BACKEND" = "$EXPECT" ] || fail "本形状期望选中 $EXPECT，实际选中 ${BACKEND:-（无）}"

say "隔离验收（preflight，真去读那些不该读到的东西）"
if ! bash "$R/scripts/preflight-sandbox.sh" zhangsan 2>&1 | tee /tmp/preflight.txt; then
  fail "隔离验收有未通过项，见上方 ❌"
fi
grep -q "隔离验收通过" /tmp/preflight.txt || fail "preflight 没跑出结论"
echo "✅ 形状 $EXPECT：选档正确，且隔离验收全通过"
