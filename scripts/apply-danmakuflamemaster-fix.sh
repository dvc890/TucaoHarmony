#!/bin/bash
# 将本仓库维护的 @ohos/danmakuflamemaster 2.1.3 修复覆写进 oh_modules。
# 背景：oh_modules 被 gitignore，任何 ohpm install 都会用官方原始包覆盖掉修复。
# 用法：在执行过 ohpm install 之后、构建之前运行本脚本。
#   bash scripts/apply-danmakuflamemaster-fix.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$REPO_ROOT/patches/danmakuflamemaster-2.1.3"
TARGET="oh_modules/.ohpm/@ohos+danmakuflamemaster@2.1.3/oh_modules/@ohos/danmakuflamemaster/src/main/ets/components/common/master/flame/danmaku"
TARGET_ABS="$REPO_ROOT/$TARGET"

if [ ! -d "$TARGET_ABS" ]; then
  echo "[ERROR] 未找到 $TARGET"
  echo "        请先在仓库根目录执行 ohpm install，再运行本脚本。"
  exit 1
fi

CHANGED=0
for rel in controller/DrawTask.ets controller/DrawHandler.ets controller/IDrawTask.ets ui/widget/DanmakuViewV2.ets; do
  src="$PATCH_DIR/$rel"
  dst="$TARGET_ABS/$rel"
  if [ ! -f "$src" ]; then
    echo "[ERROR] 补丁文件缺失: $src"
    exit 1
  fi
  if cmp -s "$src" "$dst"; then
    echo "[OK]     $rel 已一致"
  else
    cp "$src" "$dst"
    echo "[PATCH]  $rel 已覆写"
    CHANGED=$((CHANGED + 1))
  fi
done

if [ "$CHANGED" -gt 0 ]; then
  echo "完成：覆写 $CHANGED 个文件。请重新构建（hvigor assembleHap）。"
else
  echo "完成：修复已全部就位，无需重编。"
fi
