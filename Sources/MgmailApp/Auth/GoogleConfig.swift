import Foundation

/// OAuth 客户端配置，来自用户从 Google Cloud 下载的 `oauth_client.json`。
///
/// 文件放在 `~/Library/Application Support/Mgmail/oauth_client.json`。
/// 桌面应用类型的 JSON 顶层键为 `installed`（少数情况为 `web`）。
struct GoogleConfig {
    let clientID: String
    let clientSecret: String
    let authURI: String
    let tokenURI: String

    /// scopes：`gmail.modify` 覆盖读取 + 标签/已读/归档编辑（不含永久删除）；
    /// `openid`/`profile` 用于拉取账号头像与名称（userinfo 接口）。
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "openid",
        "profile",
    ]

    /// 应用支持目录：`~/Library/Application Support/Mgmail`
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Mgmail", isDirectory: true)
    }

    /// oauth_client.json 的期望路径。
    static var clientFileURL: URL {
        supportDirectory.appendingPathComponent("oauth_client.json")
    }

    /// 尝试加载配置；文件不存在或格式不对时返回 nil。
    static func load() -> GoogleConfig? {
        guard let data = try? Data(contentsOf: clientFileURL) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // 桌面应用是 "installed"，网页应用是 "web"
        let node = (root["installed"] as? [String: Any]) ?? (root["web"] as? [String: Any])
        guard let node,
              let clientID = node["client_id"] as? String
        else { return nil }
        return GoogleConfig(
            clientID: clientID,
            clientSecret: node["client_secret"] as? String ?? "",
            authURI: node["auth_uri"] as? String ?? "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURI: node["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
        )
    }

    /// 确保支持目录存在（用于首次写入等）。
    static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}
