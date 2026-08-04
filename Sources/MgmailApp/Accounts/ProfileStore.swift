import Foundation

/// Profile 列表的持久化（存 UserDefaults，与 AccountStore 一套路子）。
enum ProfileStore {
    private static let key = "profiles.v1"
    /// 当前选中的 Profile id（nil / 缺省表示「全部」聚合）。
    private static let currentKey = "profiles.current.v1"

    static func load() -> [Profile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data) else {
            return []
        }
        return profiles
    }

    static func save(_ profiles: [Profile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func loadCurrentID() -> String? {
        UserDefaults.standard.string(forKey: currentKey)
    }

    static func saveCurrentID(_ id: String?) {
        if let id {
            UserDefaults.standard.set(id, forKey: currentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: currentKey)
        }
    }
}
