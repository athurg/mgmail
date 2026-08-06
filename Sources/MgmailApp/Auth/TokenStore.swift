import Foundation

/// 保存每个账户的 refresh token（纯文件读写）。
///
/// 存储位置：`~/Library/Application Support/Mgmail/tokens/<邮箱-摘要>.token`，
/// 权限 0600、目录 0700（仅本用户可读）。
///
/// 为什么不用钥匙串：本机（macOS 26）钥匙串 ACL 不被可靠遵守——即使设为
/// “所有应用可读”仍反复弹授权，开发期每次重编译都要点一遍。
///
/// **这是一次明确的安全降级，不是等价替换**：钥匙串项即便放宽了 ACL，取用时
/// 仍受进程签名门控；而普通文件不受任何门控，凡是以当前用户身份运行的程序
/// 都能直接读走这份长期凭据。换来的是不弹窗。要收紧就换回钥匙串。
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
        tokensDirectory.appendingPathComponent(StorageKey.account(email) + ".token")
    }

    /// 令牌目录。一次性迁移要按旧名字找文件，所以不能藏起来。
    static var tokensDirectory: URL {
        let dir = GoogleConfig.supportDirectory.appendingPathComponent("tokens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}
