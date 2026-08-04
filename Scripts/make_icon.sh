#!/bin/bash
# 从 Resources/AppIcon.svg 生成 Resources/AppIcon.icns（含各 Retina 尺寸）。
# 依赖：rsvg-convert（brew install librsvg）与 iconutil（macOS 自带）。
# 图标改动后重新运行本脚本，再执行 Scripts/build_app.sh 即可。
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/AppIcon.svg"
ICNS="Resources/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "缺少 rsvg-convert，请先： brew install librsvg" >&2
  exit 1
fi
if [[ ! -f "$SVG" ]]; then
  echo "找不到 $SVG" >&2
  exit 1
fi

WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$WORK"' EXIT

# iconutil 要求的标准命名与尺寸；直接从矢量渲染各尺寸以保证清晰
render() { rsvg-convert -w "$1" -h "$1" "$SVG" -o "$ICONSET/$2"; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "生成完成: $ICNS"
