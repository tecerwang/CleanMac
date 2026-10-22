#!/bin/bash
# ============================================================
# CleanMac 一键部署脚本 —— 无需 Apple Developer 付费账号
#
# 原理：使用 Ad-hoc 签名（"Sign to Run Locally"）构建，
#       然后把 .app 安装到 /Applications。
# 免费账号 / 无账号 均可使用；付费开发者账号仅用于
# App Store 上架与对外分发公证。
#
# 用法：
#   ./deploy.sh                        # 构建 Release 并安装到 /Applications
#   INSTALL_DIR=/tmp/x ./deploy.sh     # 安装到自定义位置（测试用）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

# 若 xcode-select 指向 CommandLineTools，自动改用完整 Xcode
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        echo "==> 已自动切换 DEVELOPER_DIR 到 /Applications/Xcode.app"
    else
        echo "错误：找不到可用的 Xcode（xcodebuild 不可用）。" >&2
        exit 1
    fi
fi

CONFIG="${1:-Release}"
DERIVED="build"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

echo "==> 使用 Ad-hoc 签名构建 ${CONFIG} 版本（无需 Apple Developer）…"
xcodebuild -project CleanMac.xcodeproj -scheme CleanMac \
    -configuration "${CONFIG}" \
    -derivedDataPath "${DERIVED}" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    -destination 'platform=macOS' \
    build | tail -6

APP="${DERIVED}/Build/Products/${CONFIG}/CleanMac.app"
[ -d "${APP}" ] || { echo "错误：构建产物不存在：${APP}" >&2; exit 1; }

echo "==> 关闭正在运行的 CleanMac…"
osascript -e 'quit app "CleanMac"' 2>/dev/null || true
sleep 1

DEST="${INSTALL_DIR}/CleanMac.app"
mkdir -p "${INSTALL_DIR}"
rm -rf "${DEST}"
cp -R "${APP}" "${DEST}"

echo "==> 注册到 Launch Services（图标与关联）…"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "${DEST}" 2>/dev/null || true

echo "==> 启动应用…"
open "${DEST}"

echo ""
echo "✅ 部署完成：${DEST}"
echo "   - 之后直接双击图标或从 Launchpad 启动，无需 Xcode"
echo "   - 可拖入 Dock 常驻"
echo "   - 提示：重新部署后请在 系统设置 → 隐私与安全性 →"
echo "     完全磁盘访问权限 中重新勾选 CleanMac"
