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
echo "⚠️  内含 refresh token（可直接访问你的 Gmail）。请妥善保管，切勿外传，也不要提交进代码仓库。"
