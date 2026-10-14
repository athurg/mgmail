import Foundation

/// 账户元数据的持久化（邮箱 + 显示名 + 备注 + 头像 URL + 代表色），存在 `settings.json`；
/// 敏感的 refresh token 单独存受权限保护的文件，见 `TokenStore`。
enum AccountStore {
    /// 读取已保存的账户列表。
    static func load() -> [Account] {
        SettingsStore.shared.current.accounts.map {
            Account(email: $0.email, displayName: $0.displayName, note: $0.note ?? "",
                    avatarURL: $0.avatarURL, colorHex: $0.colorHex)
        }
    }

    /// 保存账户列表。
    static func save(_ accounts: [Account]) {
        let stored = accounts.map {
            StoredAccount(email: $0.email, displayName: $0.displayName, note: $0.note,
                          avatarURL: $0.avatarURL, colorHex: $0.colorHex)
        }
        SettingsStore.shared.update { $0.accounts = stored }
    }
}
