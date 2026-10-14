import Foundation

/// Profile 列表的持久化（存 `settings.json`，与 AccountStore 一套路子）。
enum ProfileStore {
    static func load() -> [Profile] {
        SettingsStore.shared.current.profiles
    }

    static func save(_ profiles: [Profile]) {
        SettingsStore.shared.update { $0.profiles = profiles }
    }

    /// 当前选中的 Profile id（nil / 缺省表示「全部」聚合）。
    static func loadCurrentID() -> String? {
        SettingsStore.shared.current.currentProfileID
    }

    static func saveCurrentID(_ id: String?) {
        SettingsStore.shared.update { $0.currentProfileID = id }
    }
}
