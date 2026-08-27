#!/bin/bash
# =====================================================================
# 初始化/同步共享 profile 的补丁层：
#   1. clamped-picker 目录选择器钳制插件（多租户限根）
#   2. dsh-schedule 定时任务插件
#
# 部署到 $DSH_ROOT/.local/share/dsh/profiles/web/。新用户由 admin/core.py
# 的 _seed_dsh_home 从共享 profile 复制，自动继承本补丁。
#
# 用法:
#   scripts/init-profile.sh             # 用默认 $HOME 作为部署根
#   DSH_ROOT=/home/robot scripts/init-profile.sh
#
# 幂等：可重复执行，改动只会落到 clamped-picker 源码与 cordis.patch.yml。
# =====================================================================
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-$HOME}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

PROFILE_DIR="$DSH_ROOT/.local/share/dsh/profiles/web"
CLAMPED_SRC="$SELF_DIR/../dsh-plugin-clamped-picker/index.mjs"
CLAMPED_DST="$PROFILE_DIR/clamped-picker/index.mjs"
PATCH_FILE="$PROFILE_DIR/cordis.patch.yml"

mkdir -p "$(dirname "$CLAMPED_DST")"

# 1) clamped-picker 源码（目录选择器钳制，多租户限根）
if [ -f "$CLAMPED_SRC" ]; then
  if ! cmp -s "$CLAMPED_SRC" "$CLAMPED_DST" 2>/dev/null; then
    cp "$CLAMPED_SRC" "$CLAMPED_DST"
    echo "clamped-picker 已更新: $CLAMPED_DST"
  fi
else
  echo "警告: 找不到 clamped-picker 源码 $CLAMPED_SRC，跳过（目录钳制可能失效）" >&2
fi

# 2) cordis.patch.yml：clamped-picker 钳制 + dsh-schedule 定时任务
#    clamped-picker 路径随部署根而变，用 $DSH_ROOT 生成而非硬编码。
CLAMPED_PATH="$PROFILE_DIR/clamped-picker/index.mjs"
cat > "$PATCH_FILE" <<EOF
# Your patch layer for this dsh profile, applied after every bundle layer:
# a top-level YAML array of loader patch entries (id-targeted config
# overrides, disables, and insert lists; \`!!js\` expressions allowed).
#
# 本文件由 scripts/init-profile.sh 生成，请勿手工编辑；要增删插件改那个脚本。

# 目录选择器多租户钳制：
# - 必须禁用 id=directory-picker 的 -auto 选择器：它在运行时通过
#   ctx.loader.create 晚挂载 stock browse 后端，时序在 patch 条目之后，
#   会把 ctx.directoryPicker 覆盖回不钳制的实现。
# - 直接挂载 clamped-picker（BrowseDirectoryPicker 子类，按进程环境变量
#   DSH_ALLOWED_ROOT / DSH_ALLOWED_ROOTS 钳制 list/createDirectory 并裁剪
#   根目录之上的面包屑；未设置该变量时退化为 stock 行为）。
# - 各实例的 DSH_ALLOWED_ROOT 在 dsh-sandbox.sh 启动进程时注入。
- id: directory-picker
  disabled: true
- insert:
    - name: $CLAMPED_PATH
    - name: "@deepseek-ai/dsh-client-ui-directory-picker-browse"

# 定时任务（schedule_create / schedule_list / schedule_delete 三个工具）。
# dsh-schedule 是纯 function plugin（无 bundle patch），按 README 要求须在
# sessions/agents/tools/sessionPersistence 之后加载——这里在所有 bundle 层
# 之后 insert，顺序天然满足。
- insert:
    - id: schedule
      name: "@deepseek-ai/dsh-schedule"
EOF

echo "cordis.patch.yml 已生成: $PATCH_FILE"

# 3) dsh-schedule-ui 定时任务管理界面（bundle 插件，可 pnpm 安装/卸载）
SCHEDULE_UI_SRC="$SELF_DIR/../dsh-plugin-schedule-ui"
SCHEDULE_UI_DEPLOY="$DSH_ROOT/dsh-plugin-schedule-ui"
if [ -d "$SCHEDULE_UI_SRC" ]; then
  if [ ! "$SCHEDULE_UI_SRC" -ef "$SCHEDULE_UI_DEPLOY" ]; then
    mkdir -p "$SCHEDULE_UI_DEPLOY"
    cp -r "$SCHEDULE_UI_SRC/." "$SCHEDULE_UI_DEPLOY/"
  fi
  if [ -f "$PROFILE_DIR/package.json" ]; then
    export PATH="$DSH_ROOT/node/bin:$PATH"
    if ! grep -q '"dsh-schedule-ui"' "$PROFILE_DIR/package.json"; then
      (cd "$PROFILE_DIR" && pnpm add "file:$SCHEDULE_UI_DEPLOY" >/dev/null 2>&1) || \
        echo "警告: pnpm 安装 dsh-schedule-ui 失败，管理界面可能不可用" >&2
    fi
    python3 - "$PROFILE_DIR/package.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
bundles = d.setdefault('dsh', {}).setdefault('profile', {}).setdefault('bundles', [])
if 'dsh-schedule-ui' not in bundles:
    bundles.append('dsh-schedule-ui')
    with open(p, 'w') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f"bundles 已加 dsh-schedule-ui: {p}")
PY
  fi
else
  echo "警告: 找不到 dsh-schedule-ui 源码 $SCHEDULE_UI_SRC，跳过（定时任务管理界面不可用）" >&2
fi
