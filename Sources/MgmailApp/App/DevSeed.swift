import Foundation

/// 开发包第一次启动时的一次性准备：把正式包的 `oauth_client.json` 抄一份过来。
///
/// 开发包用自己的数据目录（见 `AppFlavor`），所以什么都没有；账号重新添加是一次浏览器授权，
/// 无所谓，但 OAuth 客户端配置得去 Google Cloud Console 下载，六步的活儿没必要再干一遍。
/// 只抄这一个文件：令牌、缓存都不抄——账号列表在 UserDefaults 里，本来就跟着 bundle id 分开了，
/// 抄了令牌也只是没人认领的孤儿文件。
///
/// 幂等：目标文件已经在了就什么都不做。正式包里调用等于空操作。
enum DevSeed {
    static func run() {
        guard AppFlavor.current == .dev else { return }
        let fm = FileManager.default
        let target = GoogleConfig.clientFileURL
        guard !fm.fileExists(atPath: target.path) else { return }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let source = base
            .appendingPathComponent(AppFlavor.release.supportDirectoryName, isDirectory: true)
            .appendingPathComponent(target.lastPathComponent)
        guard fm.fileExists(atPath: source.path) else { return }
        GoogleConfig.ensureSupportDirectory()
        try? fm.copyItem(at: source, to: target)
    }
}
