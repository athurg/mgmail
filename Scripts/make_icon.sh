#!/bin/bash
# 从 Resources/AppIcon.svg 生成 .icns（含各 Retina 尺寸）。
#   Scripts/make_icon.sh          # 正式包图标 Resources/AppIcon.icns
#   Scripts/make_icon.sh dev      # 开发包图标 Resources/AppIconDev.icns：同一张图右下角压一枚橙色 DEV 角标
#   Scripts/make_icon.sh all      # 两个都生成
# 依赖：rsvg-convert（brew install librsvg）与 iconutil（macOS 自带）。
# 图标改动后重新运行本脚本（改了底图记得 all），再执行打包脚本即可。
set -euo pipefail
cd "$(dirname "$0")/.."

FLAVOR="${1:-release}"
if [[ "$FLAVOR" == "all" ]]; then
  "$0" release
  "$0" dev
  exit 0
fi

SVG="Resources/AppIcon.svg"
case "$FLAVOR" in
  release) ICNS="Resources/AppIcon.icns" ;;
  dev)     ICNS="Resources/AppIconDev.icns" ;;
  *) echo "未知参数: $FLAVOR（只认 release / dev / all）" >&2; exit 2 ;;
esac

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

# 开发包图标不另存一份 SVG——底图改了两份要同步改，迟早漏一份。
# 而是把角标那几行接在原 SVG 的 </svg> 之前，现拼现渲染。
# 角标压在圆角方底的下沿（方底 y 到 924，信封到 736），缩到 16px 也还是条橙色横杠，认得出。
if [[ "$FLAVOR" == "dev" ]]; then
  DEV_SVG="$WORK/AppIconDev.svg"
  sed '$d' "$SVG" > "$DEV_SVG"   # 去掉最后一行 </svg>
  cat >> "$DEV_SVG" <<'BADGE'
  <!-- 开发包角标 -->
  <g>
    <rect x="292" y="776" width="440" height="118" rx="59" fill="#FF6A00" stroke="#ffffff" stroke-width="14"/>
    <text x="512" y="836" text-anchor="middle" dominant-baseline="central"
          font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-weight="800" font-size="92"
          letter-spacing="10" fill="#ffffff">DEV</text>
  </g>
</svg>
BADGE
  SVG="$DEV_SVG"
fi

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
