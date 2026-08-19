#!/bin/bash
# 跑一遍本地搜索的自检。
#
# 和 check_mailbox.sh 同一个路数：项目按设计不依赖完整 Xcode（见 README），
# 没有 XCTest 也没有 swift-testing。MailSearch.swift 是纯 Foundation 的，
# 单独拿 swiftc 编出来跑就行。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
    Scripts/SearchCheck.swift \
    Sources/MgmailApp/Gmail/MailSearch.swift \
    -o "$OUT/search-check"

"$OUT/search-check"
