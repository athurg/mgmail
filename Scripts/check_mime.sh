#!/bin/bash
# 跑一遍报文拼装的自检。
#
# 这本该是 swift test，但项目按设计不依赖完整 Xcode（见 README），
# 没有 XCTest 也没有 swift-testing。好在 MimeBuilder 这条链是纯 Foundation 的，
# 单独拿 swiftc 编出来跑就行。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
    Scripts/MimeCheck.swift \
    Sources/MgmailApp/Compose/MimeBuilder.swift \
    Sources/MgmailApp/Compose/OutgoingMail.swift \
    Sources/MgmailApp/Gmail/MimeParser.swift \
    Sources/MgmailApp/Gmail/Models.swift \
    -o "$OUT/mime-check"

"$OUT/mime-check"
