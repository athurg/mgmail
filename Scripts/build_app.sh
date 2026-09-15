#!/bin/bash
# 编译 MgmailApp 并组装成开发包 dist/Mgmail\ Dev.app。
#
# 出的永远是「开发包」身份（名字 Mgmail Dev、bundle id 加 .dev 后缀、带 DEV 角标的图标、
# 独立的数据目录、不参与自动更新），和 /Applications 里装的正式包互不相干，
# 可以同时跑、一眼分得清。正式包由 Scripts/package_dist.sh 出。
# 用法：
#   Scripts/build_app.sh          # release 编译并打包
#   Scripts/build_app.sh debug    # debug 编译并打包
#   Scripts/build_app.sh run      # 打包后 open 启动
#   Scripts/build_app.sh debug run
set -euo pipefail

# 切到仓库根目录（脚本在 Scripts/ 下）
cd "$(dirname "$0")/.."
source Scripts/app_bundle.sh
set_flavor dev

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

DIST="dist"
APP_DIR="$DIST/$APP_NAME.app"
SHORT_VERSION="$(app_version)"
BUILD_NUMBER="$(app_build)"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "找不到可执行文件: $BIN_PATH" >&2
  exit 1
fi

echo "==> 组装 ${APP_DIR}（版本 ${SHORT_VERSION}，构建 ${BUILD_NUMBER}）"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
copy_app_icon "$APP_DIR"
write_info_plist "$APP_DIR" "$SHORT_VERSION" "$BUILD_NUMBER"

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
echo "    这是开发包（${BUNDLE_ID}），数据在 ~/Library/Application Support/${APP_NAME}/，与正式包互不干扰。"

if [[ "$DO_RUN" == "yes" ]]; then
  echo "==> 启动 $APP_NAME"
  open "$APP_DIR"
fi
