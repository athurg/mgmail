#!/bin/bash
# 打一个可分发到其它 Mac 的安装包：
#  - 通用二进制（arm64 + x86_64），兼容 Apple Silicon 与 Intel
#  - ad-hoc 代码签名（不依赖本机的 Mgmail Dev 证书，避免目标机报“已损坏”）
#  - 产物：dist/Mgmail.zip
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Mgmail"
BUNDLE_ID="com.mgmail.app"
EXECUTABLE="MgmailApp"
DIST="dist"
APP_DIR="$DIST/$APP_NAME.app"

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

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP_DIR"

echo "==> 打包 zip"
ZIP="$DIST/$APP_NAME.zip"
rm -f "$ZIP"
# 用 ditto 保留 macOS 元数据
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"

echo ""
echo "✅ 完成：$ZIP （$ARCH_NOTE）"
echo "   分发到其它 Mac 后，见新机安装说明。"
