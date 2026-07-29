import Foundation

/// 保存每个账户的 refresh token（纯文件读写）。
///
/// 存储位置：`~/Library/Application Support/Mgmail/tokens/<邮箱>.token`，权限 0600（仅本用户可读）。
/// 说明：本机（macOS 26）钥匙串 ACL 不被可靠遵守——即使设为“所有应用可读”仍反复弹授权，
/// 故改用受权限保护的本地文件（安全性等同用户已接受的“所有应用可读”，且永不弹窗）。
/// 旧钥匙串条目的一次性迁移见独立模块 `TokenMigration`。
enum TokenStore {
    static func saveRefreshToken(_ token: String, for email: String) {
        let url = fileURL(for: email)
        try? Data(token.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func refreshToken(for email: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: email)),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func deleteRefreshToken(for email: String) {
        try? FileManager.default.removeItem(at: fileURL(for: email))
    }

    // MARK: - 文件位置

    static func fileURL(for email: String) -> URL {
        tokensDir().appendingPathComponent(sanitize(email) + ".token")
    }

    private static func tokensDir() -> URL {
        let dir = GoogleConfig.supportDirectory.appendingPathComponent("tokens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "_" : result
    }
}
