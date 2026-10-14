import SwiftUI

/// 应用的全部配置，落在 `<支持目录>/settings.json` 一个文件里。
///
/// 原先散在 UserDefaults（`~/Library/Preferences/com.mgmail.app.plist`）里，换机器要
/// `defaults export/import`，还得和支持目录里的令牌、缓存分两头搬。现在整个支持目录拷走就是
/// 全部——账号、分组、各项设置都在这一份里，人也读得懂、改得动（改之前先退出应用，
/// 否则它下次保存会把手改的覆盖掉）。
///
/// 只放「配置」：栏宽、标签树展开到哪、过滤器选了什么这类界面状态仍在 UserDefaults
/// （见 `SettingsKey`）。它们改得勤（拖一下栏宽就是几十次），丢了也不心疼，不值得进文件。
///
/// 文件里缺的键按这里的默认值算，多出来的键忽略：新版本加一项设置，不用迁移老文件。
struct AppSettings: Codable, Equatable {
    var accounts: [StoredAccount] = []
    var profiles: [Profile] = []
    /// 当前选中的 Profile id（nil 表示「全部」聚合）。
    var currentProfileID: String?
    var display = Display()
    var sync = Sync()
    var notify = Notify()
    var update = Update()

    struct Display: Codable, Equatable {
        /// 是否按会话（Thread）合并显示邮件。默认关闭，即每行只显示一封邮件。
        var conversationView = false
        /// 是否默认加载邮件中的远程内容（图片/样式等）。默认关闭，与 Apple Mail 一致。
        ///
        /// 关闭不只是为了隐私：WebKit 在远程资源加载完之前不渲染任何内容，
        /// 一封带几个外链图片的邮件，正文要等上一两秒才出得来；挡掉之后是秒开。
        var loadRemoteContentByDefault = false
    }

    struct Sync: Codable, Equatable {
        /// 每个账户最多回溯多少封邮件。
        var backfillLimit = 500
        /// 每个账户最多回溯多少天。
        var backfillDays = 90
    }

    struct Notify: Codable, Equatable {
        /// 新邮件通知总开关。
        var enabled = true
        /// 只通知「主要」邮件（推广/社交/论坛不弹）。
        var mainCategoryOnly = true
        /// 通知带提示音。
        var sound = true
        /// 在 Dock 图标上显示未读数。
        var dockBadge = true
        /// 被静音的账号（邮箱地址，排好序）。
        var mutedAccounts: [String] = []
    }

    struct Update: Codable, Equatable {
        /// 定时同步时顺带检查更新。
        var autoCheck = true
        /// 更新渠道：`stable` 只跟 tag，`dev` 跟 main 的每次合并。
        /// 存原始字符串：认不出的值落回 stable，而不是让整个文件解不开。
        var channel = UpdateChannel.stable.rawValue
        /// 用户点过「跳过此版本」的那个构建号，定时检查不再提它。
        var skippedBuild = 0
    }
}

/// 账户元数据（邮箱 + 显示名 + 备注 + 头像 URL + 代表色）。refresh token 不在这里，见 `TokenStore`。
struct StoredAccount: Codable, Equatable {
    let email: String
    let displayName: String
    var note: String?
    var avatarURL: String?
    var colorHex: String?
}

/// `settings.json` 的读写。读多写少：同步管线、通知、更新检查随时来读，
/// 只有用户改设置、增删账号、切分组时才写，每次写整份文件（就几 KB）。
///
/// 读写都可能来自后台（同步管线里判断要不要弹通知），所以内存里那份由锁守着；
/// 写盘也在锁里做，两次修改不会以相反的顺序落盘。
final class SettingsStore: ObservableObject, @unchecked Sendable {
    static let shared = SettingsStore()

    private let lock = NSLock()
    private var settings: AppSettings
    private let fileURL: URL

    private init() {
        // 它多半是第一个碰数据目录的：开发包得先从正式包克隆完，才轮得到这里去读、去建目录——
        // 目录一旦存在，DevSeed 就当已经克隆过了（见 DevSeed.run）
        DevSeed.run()
        fileURL = GoogleConfig.supportDirectory.appendingPathComponent("settings.json")
        settings = Self.load(from: fileURL)
    }

    /// 当前配置的一份快照。
    var current: AppSettings {
        lock.withLock { settings }
    }

    /// 改配置。真有变化才写盘、才通知界面。
    /// 闭包在锁里跑，里面别再碰 `current` / `update`——NSLock 不可重入，会当场卡死。
    func update(_ change: (inout AppSettings) -> Void) {
        let changed: Bool = lock.withLock {
            var next = settings
            change(&next)
            guard next != settings else { return false }
            settings = next
            Self.write(next, to: fileURL)
            return true
        }
        guard changed else { return }
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    // MARK: - 文件

    private static func load(from url: URL) -> AppSettings {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // 还没有这份文件：老版本的配置都在 UserDefaults 里，搬过来
            let (migrated, found) = LegacyDefaults.read()
            if found, write(migrated, to: url) {
                LegacyDefaults.remove()
            }
            return migrated
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            // 解不开（多半是手改坏了）：挪到一边留着，按默认值起步。不能原地覆盖——
            // 那是用户的账号列表，改好了换回原名，重启应用就回来了
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let aside = url.deletingPathExtension().appendingPathExtension("broken-\(stamp).json")
            try? fm.moveItem(at: url, to: aside)
            NSLog("SettingsStore: %@ 解析失败（%@），已挪到 %@，按默认设置启动",
                  url.path, String(describing: error), aside.lastPathComponent)
            return AppSettings()
        }
    }

    /// 宽松解码：把文件内容逐层盖在默认值上再解，缺的键就是默认值。
    /// Codable 自己遇到缺键只会报错，逐个字段写 `decodeIfPresent` 又是一大片样板。
    static func decode(_ data: Data) throws -> AppSettings {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any] ?? [:]
        guard let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let merged = overlay(file, on: defaults)
        return try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    private static func overlay(_ top: [String: Any], on base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in top {
            if let nested = value as? [String: Any], let under = base[key] as? [String: Any] {
                result[key] = overlay(nested, on: under)
            } else {
                result[key] = value
            }
        }
        return result
    }

    @discardableResult
    private static func write(_ settings: AppSettings, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        // 排好序、缩进好：人要能看、要能 diff
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            GoogleConfig.ensureSupportDirectory()
            try encoder.encode(settings).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("SettingsStore: 写 %@ 失败：%@", url.path, String(describing: error))
            return false
        }
    }
}

/// 视图里用的设置项，用法同 `@AppStorage`：`@Setting(\.display.conversationView) var conversationView`，
/// `$conversationView` 是 Binding。默认值在 `AppSettings` 里定，不在各个视图里各写一遍。
@propertyWrapper
struct Setting<Value>: DynamicProperty {
    @ObservedObject private var store = SettingsStore.shared
    private let keyPath: WritableKeyPath<AppSettings, Value>

    init(_ keyPath: WritableKeyPath<AppSettings, Value>) {
        self.keyPath = keyPath
    }

    var wrappedValue: Value {
        get { store.current[keyPath: keyPath] }
        nonmutating set { store.update { $0[keyPath: keyPath] = newValue } }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// 老版本存在 UserDefaults 里的配置。键名今后只在这里出现：搬完就删，主逻辑不该知道它们。
enum LegacyDefaults {
    private static let keys = [
        "accounts.v1", "profiles.v1", "profiles.current.v1",
        "conversationView", "loadRemoteContentByDefault",
        "sync.backfillLimit", "sync.backfillDays",
        "notify.enabled", "notify.mainCategoryOnly", "notify.sound", "notify.dockBadge", "notify.mutedAccounts",
        "update.autoCheck", "update.channel", "update.skippedBuild",
    ]

    /// 读出老配置；`found` 表示至少有一个键在（全新安装就是 false，不必写文件）。
    static func read(from d: UserDefaults = .standard) -> (AppSettings, found: Bool) {
        var s = AppSettings()
        if let data = d.data(forKey: "accounts.v1"),
           let accounts = try? JSONDecoder().decode([StoredAccount].self, from: data) {
            s.accounts = accounts
        }
        if let data = d.data(forKey: "profiles.v1"),
           let profiles = try? JSONDecoder().decode([Profile].self, from: data) {
            s.profiles = profiles
        }
        s.currentProfileID = d.string(forKey: "profiles.current.v1")
        func bool(_ key: String, _ apply: (Bool) -> Void) {
            if let v = d.object(forKey: key) as? Bool { apply(v) }
        }
        func positive(_ key: String, _ apply: (Int) -> Void) {
            let v = d.integer(forKey: key)
            if v > 0 { apply(v) }
        }
        bool("conversationView") { s.display.conversationView = $0 }
        bool("loadRemoteContentByDefault") { s.display.loadRemoteContentByDefault = $0 }
        positive("sync.backfillLimit") { s.sync.backfillLimit = $0 }
        positive("sync.backfillDays") { s.sync.backfillDays = $0 }
        bool("notify.enabled") { s.notify.enabled = $0 }
        bool("notify.mainCategoryOnly") { s.notify.mainCategoryOnly = $0 }
        bool("notify.sound") { s.notify.sound = $0 }
        bool("notify.dockBadge") { s.notify.dockBadge = $0 }
        if let muted = d.stringArray(forKey: "notify.mutedAccounts") { s.notify.mutedAccounts = muted.sorted() }
        bool("update.autoCheck") { s.update.autoCheck = $0 }
        if let channel = d.string(forKey: "update.channel") { s.update.channel = channel }
        positive("update.skippedBuild") { s.update.skippedBuild = $0 }
        return (s, keys.contains { d.object(forKey: $0) != nil })
    }

    /// 文件写成功之后才删：写失败就留着，下次启动再搬一遍。
    static func remove(from d: UserDefaults = .standard) {
        for key in keys { d.removeObject(forKey: key) }
    }
}
