#!/bin/bash
# 打一个可分发到其它 Mac 的安装包（正式包身份：Mgmail / com.mgmail.app）：
#  - 通用二进制（arm64 + x86_64），兼容 Apple Silicon 与 Intel
#  - ad-hoc 代码签名（不依赖本机的 Mgmail Dev 证书，避免目标机报“已损坏”）
#  - 产物：dist/Mgmail.zip，以及应用内检查更新要读的 dist/manifest.json
#
# CI（.github/workflows/release.yml）跑的就是这个脚本，本地也能直接跑。
# 可选环境变量：
#   MGMAIL_TAG         这一包将挂在哪个 GitHub Release 下（决定 manifest 里的下载地址）
#   MGMAIL_CHANNEL     stable | dev（写进 manifest，只作展示）
#   MGMAIL_NOTES_FILE  更新说明（Markdown 文件路径），写进 manifest 给应用内弹窗显示
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/app_bundle.sh
set_flavor release

DIST="dist"
APP_DIR="$DIST/$APP_NAME.app"
SHORT_VERSION="$(app_version)"
BUILD_NUMBER="$(app_build)"

# 无完整 Xcode 无法一次编通用二进制（缺 xcbuild），改为分别交叉编译再 lipo 合并
echo "==> 编译 arm64"
swift build -c release --arch arm64 >/dev/null
ARM_BIN="$(swift build -c release --arch arm64 --show-bin-path)/$EXECUTABLE"

BIN_PATH="$(mktemp -d)/$EXECUTABLE"
if swift build -c release --arch x86_64 >/dev/null 2>&1; then
  echo "==> 编译 x86_64 并用 lipo 合成通用二进制"
  X86_BIN="$(swift build -c release --arch x86_64 --show-bin-path)/$EXECUTABLE"
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$BIN_PATH"
  ARCH_NOTE="通用二进制 ($(lipo -archs "$BIN_PATH"))"
else
  echo "   x86_64 编译失败，仅用 arm64"
  cp "$ARM_BIN" "$BIN_PATH"
  ARCH_NOTE="仅 arm64（Apple Silicon）"
fi

echo "==> 组装 ${APP_DIR}（版本 ${SHORT_VERSION}，构建 ${BUILD_NUMBER}）"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
copy_app_icon "$APP_DIR"
write_info_plist "$APP_DIR" "$SHORT_VERSION" "$BUILD_NUMBER"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 打包 zip"
ZIP="$DIST/$APP_NAME.zip"
rm -f "$ZIP"
# 用 ditto 保留 macOS 元数据
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

# 应用内检查更新读的就是这份 manifest：比 GitHub 的 Releases API 省事——
# 不受匿名调用 60 次/小时的限额，也不用解析那一大坨 JSON；顺带把校验和一起带上。
echo "==> 生成 manifest.json"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(stat -f %z "$ZIP")"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo "")"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TAG="${MGMAIL_TAG:-}"
URL=""
if [[ -n "$TAG" ]]; then
  URL="https://github.com/athurg/mgmail/releases/download/$TAG/$APP_NAME.zip"
fi
NOTES_FILE="${MGMAIL_NOTES_FILE:-}"
[[ -f "$NOTES_FILE" ]] || NOTES_FILE="/dev/null"
# 用 python 拼 JSON：说明里有引号、换行，手工转义迟早出错
python3 - "$DIST/manifest.json" "$NOTES_FILE" <<PYEOF
import json, sys
json.dump({
    "version": "$SHORT_VERSION",
    "build": $BUILD_NUMBER,
    "commit": "$COMMIT",
    "channel": "${MGMAIL_CHANNEL:-}",
    "tag": "$TAG",
    "url": "$URL",
    "asset": "$APP_NAME.zip",
    "sha256": "$SHA256",
    "size": $SIZE,
    "minSystem": "14.0",
    "builtAt": "$BUILT_AT",
    "notes": open(sys.argv[2], encoding="utf-8").read().strip(),
}, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF

echo ""
echo "✅ 完成：$ZIP （${ARCH_NOTE}）"
echo "   manifest：$DIST/manifest.json"
echo "   分发到其它 Mac 后，见新机安装说明。"
