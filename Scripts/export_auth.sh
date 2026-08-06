#!/bin/bash
# 在【本机】导出 Mgmail 的核心认证数据，供拷贝到其它 Mac 免登录使用。
# 产物默认写到 ~/Desktop/Mgmail-auth.zip（可传参指定输出路径）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/Mgmail"
OUT="${1:-$HOME/Desktop/Mgmail-auth.zip}"
TMP="$(mktemp -d)"
STAGE="$TMP/Mgmail-auth"
mkdir -p "$STAGE"

# OAuth 客户端配置
if [[ -f "$SUPPORT/oauth_client.json" ]]; then
  cp "$SUPPORT/oauth_client.json" "$STAGE/"; echo "   oauth_client.json ✓"
else
  echo "   ⚠️ 未找到 oauth_client.json"
fi

# refresh token 文件（免登录关键）
if [[ -d "$SUPPORT/tokens" ]]; then
  cp -R "$SUPPORT/tokens" "$STAGE/"; echo "   tokens/ ✓"
else
  echo "   ⚠️ 未找到 tokens/（可能还没登录过账号）"
fi

# 账号列表与界面偏好（UserDefaults）
if defaults export com.mgmail.app "$STAGE/prefs.plist" 2>/dev/null; then
  echo "   账号列表/偏好 ✓"
else
  echo "   ⚠️ 无法导出偏好（账号列表）"
fi

# 附带新机安装脚本，便于对方一键安装
cp "$HERE/setup_on_new_mac.sh" "$STAGE/" 2>/dev/null || true

rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT"
chmod 600 "$OUT"
rm -rf "$TMP"

echo ""
echo "✅ 已导出：$OUT"
echo "⚠️  内含 refresh token —— 拿到它就等于拿到你的 Gmail 读写权限，且它不会自己过期。"
echo "    · 只走可信通道传输（AirDrop、加密 U 盘），不要走聊天软件或网盘"
echo "    · 装完立刻删掉两端的这个文件：rm -P \"$OUT\""
echo "    · 万一外泄：到 https://myaccount.google.com/permissions 撤销 Mgmail 的授权"
