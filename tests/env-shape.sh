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

say "环境能力报告"
bash "$SANDBOX" --report 2>&1 | sed 's/^/  /'

BACKEND=$(bash "$SANDBOX" --backend 2>/dev/null || echo "")
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
