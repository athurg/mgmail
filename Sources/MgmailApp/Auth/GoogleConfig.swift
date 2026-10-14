import Foundation

/// OAuth 客户端配置，即从 Google Cloud 下载的 `oauth_client.json`。
///
/// 按顺序找两处，先找到哪份用哪份：
/// 1. `~/Library/Application Support/Mgmail/oauth_client.json`——用户自己放的，用来换成自己的客户端；
/// 2. `.app` 里 `Contents/Resources/oauth_client.json`——打包时内置的（CI 从仓库变量注入，
///    见 `Scripts/app_bundle.sh` 的 `copy_oauth_client`），装好就能直接添加账号。
///
/// 内置不算泄密：桌面应用类型的 client secret 按 Google 的说法本来就守不住，安全靠 PKCE + 回环重定向。
/// 只是不进仓库——公开源码里的客户端谁都能拿去用，配额和封号都算在这个 Cloud 项目头上。
///
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

    /// 应用支持目录：`~/Library/Application Support/Mgmail`；开发包是 `…/Mgmail Dev`（见 `AppFlavor`）。
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(AppFlavor.current.supportDirectoryName, isDirectory: true)
    }

    /// 用户自己放的 oauth_client.json 的路径（优先于内置的那份）。
    static var clientFileURL: URL {
        supportDirectory.appendingPathComponent("oauth_client.json")
    }

    /// 打包时内置进 .app 的那份；`swift run` 的裸可执行文件和本机没配客户端的开发包都没有。
    static var bundledClientFileURL: URL? {
        Bundle.main.url(forResource: "oauth_client", withExtension: "json")
    }

    /// 尝试加载配置：先用户的、再内置的；都没有或格式不对时返回 nil。
    static func load() -> GoogleConfig? {
        if let config = load(from: clientFileURL) { return config }
        if let url = bundledClientFileURL { return load(from: url) }
        return nil
    }

    private static func load(from url: URL) -> GoogleConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
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
