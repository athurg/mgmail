#!/bin/bash
# 重置开发包（Mgmail Dev）的数据：删掉它的数据目录和偏好设置。
# 下次启动开发包时会重新从正式包克隆一份快照（见 App/DevSeed.swift）。
#
# 用法：
#   Scripts/dev_reset.sh          # 清掉，下次启动从正式包克隆最新快照
#   Scripts/dev_reset.sh --empty  # 清掉，且下次启动是空环境（只留 oauth_client.json，不克隆账号和缓存）
set -euo pipefail

SUPPORT="$HOME/Library/Application Support"
DEV_DIR="$SUPPORT/Mgmail Dev"
RELEASE_DIR="$SUPPORT/Mgmail"
DEV_ID="com.mgmail.app.dev"

if pgrep -f "Mgmail Dev.app/Contents/MacOS/Mgmail Dev" >/dev/null; then
  echo "Mgmail Dev 正在运行，先退出它再重置（否则它退出时会把内存里的设置写回去）。" >&2
  exit 1
fi

echo "==> 删除 ${DEV_DIR}"
rm -rf "$DEV_DIR"
echo "==> 删除偏好域 ${DEV_ID}"
defaults delete "$DEV_ID" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--empty" ]]; then
  # 目录已存在，DevSeed 就不会克隆；只放 OAuth 客户端配置，省得再去 Google Cloud 下载
  mkdir -p "$DEV_DIR"
  if [[ -f "$RELEASE_DIR/oauth_client.json" ]]; then
    cp "$RELEASE_DIR/oauth_client.json" "$DEV_DIR/"
    echo "==> 空环境：只保留 oauth_client.json，下次启动需要重新添加账号"
  else
    echo "==> 空环境：正式包那边也没有 oauth_client.json，下次启动要先配置"
  fi
else
  echo "==> 下次启动 Mgmail Dev 时会从正式包克隆一份最新快照"
fi
