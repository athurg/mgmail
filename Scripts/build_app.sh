#!/bin/bash
# 编译 MgmailApp 并组装成 dist/Mgmail.app。
# 用法：
#   Scripts/build_app.sh          # release 编译并打包
#   Scripts/build_app.sh debug    # debug 编译并打包
#   Scripts/build_app.sh run      # 打包后 open 启动
#   Scripts/build_app.sh debug run
set -euo pipefail

# 切到仓库根目录（脚本在 Scripts/ 下）
cd "$(dirname "$0")/.."

CONFIG="release"
DO_RUN="no"
for arg in "$@"; do
  case "$arg" in
    debug)   CONFIG="debug" ;;
    release) CONFIG="release" ;;
    run)     DO_RUN="yes" ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Mgmail"
BUNDLE_ID="com.mgmail.app"
EXECUTABLE="MgmailApp"
DIST="dist"
APP_DIR="$DIST/$APP_NAME.app"

# 版本号取自最近的 git tag（形如 v1.2.3），没有 tag 就退回 0.0.0。
# 写死在脚本里的话，每次发版都得记得来改一次——而那件事一定会被忘掉。
RAW_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
SHORT_VERSION="${RAW_TAG#v}"
SHORT_VERSION="${SHORT_VERSION:-0.0.0}"
# 构建号用提交数，保证同一版本的两次构建也能区分先后
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "1")"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "找不到可执行文件: $BIN_PATH" >&2
  exit 1
fi

echo "==> 组装 $APP_DIR（版本 $SHORT_VERSION，构建 $BUILD_NUMBER）"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# 应用图标：缺失则从 SVG 现生成，再拷入 .app 的 Resources
ICON_SRC="Resources/AppIcon.icns"
if [[ ! -f "$ICON_SRC" && -x "Scripts/make_icon.sh" ]]; then
  echo "==> 未找到 ${ICON_SRC}，尝试从 SVG 生成"
  Scripts/make_icon.sh || true
fi
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "==> 已嵌入图标 AppIcon.icns"
else
  echo "==> 跳过图标：$ICON_SRC 不存在"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- 邮件正文里的图片常是明文 http（例如银行账单的版式图）。ATS 默认把这类
         子资源挡在 WKWebView 外面，用户点了「加载远程内容」也照样是空框。
         只对 web 内容开例外：网络层（Gmail API、OAuth）仍强制 https。 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoadsInWebContent</key>
        <true/>
    </dict>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <!-- 应用内拖拽（标签 → 邮件行）用的私有 UTI -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.mgmail.label</string>
            <key>UTTypeDescription</key>
            <string>Mgmail Label</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# 用固定的自签名证书签名，让 Keychain 的 designated requirement 保持稳定，
# 从而开发阶段重编译后不再反复弹钥匙串授权。
# 证书可用「钥匙串访问 → 证书助理 → 创建证书」生成（类型：代码签名，自签名根）。
SIGN_IDENTITY="${MGMAIL_SIGN_IDENTITY:-Mgmail Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  echo "==> 用「${SIGN_IDENTITY}」签名"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
  echo "==> 警告：未找到证书「${SIGN_IDENTITY}」，app 保持未签名。后果有两个："
  echo "    1) Keychain 每次重编译会重弹授权；"
  echo "    2) 新邮件通知很可能收不到——未签名的 bundle 拿不到稳定的通知身份。"
  echo "    生成证书：钥匙串访问 → 证书助理 → 创建证书（类型：代码签名，自签名根）。"
fi

echo "==> 完成: $APP_DIR"

if [[ "$DO_RUN" == "yes" ]]; then
  echo "==> 启动 $APP_NAME"
  open "$APP_DIR"
fi
