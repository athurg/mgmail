#!/bin/bash
# 跑一遍 settings.json 的自检（宽松解码、从 UserDefaults 搬家）。
#
# 和 check_search.sh 同一个路数：项目按设计不依赖完整 Xcode（见 README），
# 没有 XCTest 也没有 swift-testing。SettingsStore.swift 连同它用到的几个类型单独拿 swiftc 编出来跑。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O -parse-as-library \
    Scripts/SettingsCheck.swift \
    Sources/MgmailApp/App/SettingsStore.swift \
    Sources/MgmailApp/App/DevSeed.swift \
    Sources/MgmailApp/App/AppFlavor.swift \
    Sources/MgmailApp/Accounts/Profile.swift \
    Sources/MgmailApp/Auth/GoogleConfig.swift \
    Sources/MgmailApp/Update/UpdateManifest.swift \
    Sources/MgmailApp/Update/AppVersion.swift \
    -o "$OUT/settings-check"

"$OUT/settings-check"
