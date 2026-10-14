import Foundation

/// `settings.json` 的自检。
///
/// 和 `SearchCheck` 同一个路数（项目不依赖完整 Xcode，见 README），
/// 由 `Scripts/check_settings.sh` 把 `SettingsStore.swift` 连同它用到的几个类型单独编出来跑。
///
/// 盯的是「升级之后设置悄悄没了」的那几条路：老文件缺了新加的键、手改时漏了一层、
/// 从 UserDefaults 搬过来时把「没设过」当成了 false。这些都不报错，只会让人以为设置被重置了。
@main
struct SettingsCheck {
    static var passed = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("第 \(line) 行：\(what)")
        }
    }

    static func decode(_ json: String) -> AppSettings? {
        try? SettingsStore.decode(Data(json.utf8))
    }

    static func main() {
        // 空对象：全是默认值
        expect(decode("{}") == AppSettings(), "空文件应等于默认设置")

        // 只写了一层里的一个键：同一层的其它键保持默认，不能整层被清掉
        if let s = decode(#"{"notify": {"sound": false}}"#) {
            expect(s.notify.sound == false, "写了的键应生效")
            expect(s.notify.enabled == true && s.notify.dockBadge == true, "同层没写的键应保持默认")
            expect(s.sync.backfillLimit == 500, "别的层应保持默认")
        } else {
            expect(false, "部分嵌套应能解开")
        }

        // 认不得的键（将来的版本加的、或者手写错的名字）不该让整份解不开
        expect(decode(#"{"future": 1, "display": {"conversationView": true, "x": 2}}"#)?.display.conversationView == true,
               "多出来的键应被忽略")

        // 账号缺可选字段照样能读
        if let s = decode(#"{"accounts": [{"email": "a@x.com", "displayName": "A"}]}"#) {
            expect(s.accounts.count == 1 && s.accounts[0].note == nil, "账号的可选字段可缺")
        } else {
            expect(false, "最简账号应能解开")
        }

        // 类型写错要报错，交给调用方挪到一边，而不是静默当默认值（那会在下次保存时把账号列表抹掉）
        expect(decode(#"{"sync": {"backfillDays": "90"}}"#) == nil, "类型不对应报错")
        expect(decode("[]") == nil, "顶层不是对象应报错")
        expect(decode("not json") == nil, "不是 JSON 应报错")

        // 写出去再读回来一字不差
        var full = AppSettings()
        full.accounts = [StoredAccount(email: "a@x.com", displayName: "甲", note: "工作", avatarURL: "https://x/a.png", colorHex: "#ff3b30")]
        full.profiles = [Profile(id: "p1", name: "工作", colorIndex: 2, memberEmails: ["a@x.com"])]
        full.currentProfileID = "p1"
        full.display.conversationView = true
        full.sync.backfillDays = 365
        full.notify.mutedAccounts = ["b@x.com"]
        full.update.channel = "dev"
        full.update.skippedBuild = 42
        if let data = try? JSONEncoder().encode(full) {
            expect((try? SettingsStore.decode(data)) == full, "编码再解码应还原")
        } else {
            expect(false, "应能编码")
        }

        checkLegacy()

        print("SettingsCheck：通过 \(passed) 项")
        if !failures.isEmpty {
            failures.forEach { print("  ✗ \($0)") }
            exit(1)
        }
    }

    /// 从 UserDefaults 搬家。用一个临时的偏好域，不碰任何真实设置。
    static func checkLegacy() {
        let suite = "mgmail.settings-check.\(getpid())"
        guard let d = UserDefaults(suiteName: suite) else { return expect(false, "建临时偏好域") }
        defer { d.removePersistentDomain(forName: suite) }

        // 全新安装：什么都没有，不该当成「有东西要搬」
        let (fresh, foundFresh) = LegacyDefaults.read(from: d)
        expect(!foundFresh && fresh == AppSettings(), "空偏好域：没有可搬的，结果是默认值")

        let accounts = [StoredAccount(email: "a@x.com", displayName: "甲", note: nil, avatarURL: nil, colorHex: "#007aff")]
        d.set(try! JSONEncoder().encode(accounts), forKey: "accounts.v1")
        d.set(try! JSONEncoder().encode([Profile(id: "p1", name: "家", colorIndex: 0)]), forKey: "profiles.v1")
        d.set("p1", forKey: "profiles.current.v1")
        // 用户特意关掉的：false 必须原样搬过来，不能因为「读出来是 false」就跟「没设过」混为一谈
        d.set(false, forKey: "notify.enabled")
        d.set(true, forKey: "conversationView")
        d.set(1000, forKey: "sync.backfillLimit")
        d.set(["z@x.com", "b@x.com"], forKey: "notify.mutedAccounts")
        d.set("dev", forKey: "update.channel")
        // 界面状态不归这里管，搬完也不能被删
        d.set(300.0, forKey: "layout.listWidth")

        let (s, found) = LegacyDefaults.read(from: d)
        expect(found, "有老配置时应报告找到")
        expect(s.accounts == accounts, "账号列表应原样搬过来")
        expect(s.profiles.map(\.id) == ["p1"] && s.currentProfileID == "p1", "分组和当前分组应搬过来")
        expect(s.notify.enabled == false, "显式关掉的开关应保持关")
        expect(s.notify.sound == true, "没设过的开关应是默认的开")
        expect(s.display.conversationView == true, "会话显示应搬过来")
        expect(s.sync.backfillLimit == 1000 && s.sync.backfillDays == 90, "设过的取设的，没设的取默认")
        expect(s.notify.mutedAccounts == ["b@x.com", "z@x.com"], "静音名单应排好序")
        expect(s.update.channel == "dev" && s.update.skippedBuild == 0, "更新设置应搬过来")

        LegacyDefaults.remove(from: d)
        expect(d.object(forKey: "accounts.v1") == nil && d.object(forKey: "notify.enabled") == nil, "搬完应删掉老键")
        expect(d.double(forKey: "layout.listWidth") == 300, "界面状态的键不该被删")
        expect(!LegacyDefaults.read(from: d).found, "删完再读应是没有可搬的")
    }
}
