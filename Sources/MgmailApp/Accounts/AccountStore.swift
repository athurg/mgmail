import Foundation

/// 账户元数据的持久化（邮箱 + 显示名 + 备注 + 头像 URL）存 UserDefaults；
/// 敏感的 refresh token 单独存受权限保护的文件，见 `TokenStore`。
enum AccountStore {
    private static let key = "accounts.v1"

    private struct Stored: Codable {
        let email: String
        let displayName: String
        var note: String?
        var avatarURL: String?
    }

    /// 读取已保存的账户列表。
    static func load() -> [Account] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else {
            return []
        }
        return stored.map {
            Account(email: $0.email, displayName: $0.displayName, note: $0.note ?? "", avatarURL: $0.avatarURL)
        }
    }

    /// 保存账户列表。
    static func save(_ accounts: [Account]) {
        let stored = accounts.map {
            Stored(email: $0.email, displayName: $0.displayName, note: $0.note, avatarURL: $0.avatarURL)
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
