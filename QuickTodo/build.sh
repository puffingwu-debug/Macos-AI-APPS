#!/bin/bash
#
# 编译 QuickTodo 并组装成可双击运行的 macOS .app。
#
#   ./build.sh                 # release 构建到 dist/QuickTodo.app
#   ./build.sh debug           # 开发期更快的构建
#   ./build.sh release run     # 构建后启动
#
# 需要「屏幕录制」权限才能截图：首次运行后到
# 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 QuickTodo。
#
# 环境变量：
#   SWIFTPM_FLAGS   追加给 swift build 的参数（例如受限沙箱里用 --disable-sandbox）
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
ACTION="${2:-}"
APP_NAME="QuickTodo"
BUNDLE="dist/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG} ${SWIFTPM_FLAGS:-}"
# shellcheck disable=SC2086
swift build -c "${CONFIG}" --product "${APP_NAME}" ${SWIFTPM_FLAGS:-}

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path ${SWIFTPM_FLAGS:-})/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
  echo "!! 未找到构建产物：${BIN_PATH}" >&2
  exit 1
fi

echo "==> 组装 ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# ad-hoc 签名：本机运行足够，并能让 TCC（屏幕录制/辅助功能）权限稳定记住这个 App。
# 正式分发请替换为 Developer ID 证书。
echo "==> ad-hoc 签名"
codesign --force --deep --sign - "${BUNDLE}" 2>&1 | sed 's/^/    /' || true

echo "==> 完成：${BUNDLE}"

if [ "${ACTION}" = "run" ]; then
  echo "==> 启动"
  pkill -x "${APP_NAME}" 2>/dev/null || true
  sleep 0.4
  open "${BUNDLE}"
fi
