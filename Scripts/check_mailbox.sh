#!/bin/bash
# 跑一遍邮箱归属判断的自检。
#
# 和 check_mime.sh 同一个路数：项目按设计不依赖完整 Xcode（见 README），
# 没有 XCTest 也没有 swift-testing。好在 Mailbox.swift 是纯 Foundation 的，
# 单独拿 swiftc 编出来跑就行。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
    Scripts/MailboxCheck.swift \
    Sources/MgmailApp/Gmail/Mailbox.swift \
    -o "$OUT/mailbox-check"

"$OUT/mailbox-check"
