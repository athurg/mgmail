import Foundation
import Security

/// 一次性迁移：把旧版本存在 macOS 钥匙串里的 refresh token 迁移到文件存储（`TokenStore`）。
///
/// 只在 App 启动时显式调用一次，不参与日常读写路径。
/// 当所有用户都完成迁移后，本文件可整体删除、并移除启动处的调用，不影响主逻辑。
enum TokenMigration {
    private static let keychainService = "com.mgmail.app.oauth"

    /// 对给定账户执行迁移：文件已存在则跳过；否则从钥匙串读出写入文件并删除钥匙串条目。
    static func migrateFromKeychain(emails: [String]) {
        for email in emails {
            guard TokenStore.refreshToken(for: email) == nil else { continue }
            guard let token = keychainRead(email) else { continue }
            TokenStore.saveRefreshToken(token, for: email)
            keychainDelete(email)
        }
    }

    private static func keychainRead(_ email: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: email,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete(_ email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: email,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
