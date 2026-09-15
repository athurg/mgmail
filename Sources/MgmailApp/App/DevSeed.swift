import Foundation

/// 开发包第一次启动时的一次性准备：把正式包的数据整个克隆一份过来。
///
/// 开发包用自己的数据目录和自己的 UserDefaults（见 `AppFlavor`），所以什么都没有。
/// 从零添加账号、重新回溯同步一遍才能测，太费事；而正式包那边现成的账号、令牌、
/// 邮件池、同步位点，拿来就是一份可以立刻开测的快照——之后两边各走各的，互不影响。
///
/// 抄两样东西：
/// - `~/Library/Application Support/Mgmail/` 整个目录（`Logs/`、`updates/` 除外，那是日志和
///   下载中的更新包）。APFS 上用 `clonefile` 整棵树克隆，瞬间完成、不额外占盘，改到哪一块
///   才真正复制哪一块；不是 APFS 就退回逐项拷贝。
/// - UserDefaults 里 `com.mgmail.app` 这个域的全部键：账号列表、分组、各项设置都在里面。
///
/// 只在开发包目录**还不存在**时做，幂等；正式包里调用等于空操作。
/// 想要一份新的快照或者干净环境：`Scripts/dev_reset.sh`。
enum DevSeed {
    /// 这两个子目录不抄：日志按天滚动没意义，下载中的更新包是正式包自己的事。
    private static let skipped: Set<String> = ["Logs", "updates"]

    static func run() {
        guard AppFlavor.current == .dev else { return }
        let fm = FileManager.default
        let target = GoogleConfig.supportDirectory
        guard !fm.fileExists(atPath: target.path) else { return }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let source = base.appendingPathComponent(AppFlavor.release.supportDirectoryName, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return }

        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let entries = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        for name in entries where !skipped.contains(name) {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            if clonefile(from.path, to.path, 0) != 0 {
                try? fm.copyItem(at: from, to: to)
            }
        }

        // 另一个 bundle id 的偏好域也读得到（不是沙盒应用），整个搬到自己名下
        let releaseID = "com.mgmail.app"
        if let domain = UserDefaults.standard.persistentDomain(forName: releaseID) {
            for (key, value) in domain {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        NSLog("DevSeed: 已从正式包克隆数据到 %@", target.path)
    }
}
