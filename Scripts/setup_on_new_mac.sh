#!/bin/bash
# 在【新 Mac】上安装 Mgmail 并恢复认证数据。
# 用法：把 Mgmail.zip 和本次导出的 Mgmail-auth 目录内容放到同一个文件夹，然后运行本脚本。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/Mgmail"

echo "==> 安装 Mgmail.app 到 /Applications"
if [[ -f "$HERE/Mgmail.zip" ]]; then
  rm -rf "$HERE/_app"; mkdir -p "$HERE/_app"
  ditto -x -k "$HERE/Mgmail.zip" "$HERE/_app"
  APP="$HERE/_app/Mgmail.app"
elif [[ -d "$HERE/Mgmail.app" ]]; then
  APP="$HERE/Mgmail.app"
else
  echo "❌ 未找到 Mgmail.zip 或 Mgmail.app（请与本脚本放同一目录）"; exit 1
fi
xattr -cr "$APP" 2>/dev/null || true
rm -rf "/Applications/Mgmail.app"
cp -R "$APP" "/Applications/"
xattr -cr "/Applications/Mgmail.app" 2>/dev/null || true
rm -rf "$HERE/_app"

echo "==> 恢复认证数据到 $SUPPORT"
mkdir -p "$SUPPORT"
[[ -f "$HERE/oauth_client.json" ]] && cp "$HERE/oauth_client.json" "$SUPPORT/" && echo "   oauth_client.json ✓"
if [[ -d "$HERE/tokens" ]]; then
  cp -R "$HERE/tokens" "$SUPPORT/"
  chmod 700 "$SUPPORT/tokens" 2>/dev/null || true
  chmod 600 "$SUPPORT/tokens/"*.token 2>/dev/null || true
  echo "   tokens/ ✓"
fi
if [[ -f "$HERE/prefs.plist" ]]; then
  defaults import com.mgmail.app "$HERE/prefs.plist"
  echo "   账号列表/偏好 ✓"
fi

echo ""
echo "✅ 完成。打开 /Applications/Mgmail.app"
echo "   首次打开若提示无法验证开发者：右键点 App →「打开」→ 再点「打开」。"
echo "   若提示 refresh token 过期（测试态约 7 天），在 App 里对该账号「重新登录」即可。"
