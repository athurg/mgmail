#!/bin/bash
# 组装 Mgmail.app 时两个打包脚本共用的那几步：版本号怎么算、Info.plist 长什么样、图标从哪来。
# 用法：在脚本里 `source Scripts/app_bundle.sh`，然后调下面的函数。
#
# 抽出来是因为 Info.plist 曾经在两个脚本里各写一份，分发用的那份少了
# UTExportedTypeDeclarations（标签拖拽用的私有 UTI）和图标——同一份 plist 只有一处
# 才不会再漏。

APP_NAME="Mgmail"
BUNDLE_ID="com.mgmail.app"
EXECUTABLE="MgmailApp"

# 版本号取自最近的 git tag（形如 v1.2.3），没有 tag 就退回 0.0.0。
# 写死在脚本里的话，每次发版都得记得来改一次——而那件事一定会被忘掉。
app_version() {
  local raw
  raw="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "")"
  raw="${raw#v}"
  echo "${raw:-0.0.0}"
}

# 构建号用提交数，保证同一版本的两次构建也能区分先后。
# 应用内检查更新也拿它比较：main 上每合并一个 PR 就加一，不必打 tag 也分得出新旧。
app_build() {
  git rev-list --count HEAD 2>/dev/null || echo "1"
}

# write_info_plist <app 目录> <版本> <构建号>
write_info_plist() {
  local app_dir="$1" version="$2" build="$3"
  cat > "$app_dir/Contents/Info.plist" <<PLIST
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
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build</string>
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
}

# copy_app_icon <app 目录>
# 图标缺失则从 SVG 现生成，再拷入 .app 的 Resources。
copy_app_icon() {
  local app_dir="$1" icon_src="Resources/AppIcon.icns"
  if [[ ! -f "$icon_src" && -x "Scripts/make_icon.sh" ]]; then
    echo "==> 未找到 ${icon_src}，尝试从 SVG 生成"
    Scripts/make_icon.sh || true
  fi
  if [[ -f "$icon_src" ]]; then
    cp "$icon_src" "$app_dir/Contents/Resources/AppIcon.icns"
    echo "==> 已嵌入图标 AppIcon.icns"
  else
    echo "==> 跳过图标：$icon_src 不存在"
  fi
}
