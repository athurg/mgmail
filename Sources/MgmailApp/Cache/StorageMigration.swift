import Foundation

/// 一次性的磁盘布局迁移与陈旧文件清理。
///
/// 只在 App 启动时调一次，不参与日常读写路径——同样的道理，主逻辑里
/// 也不该有任何一处需要知道「以前的布局长什么样」。
/// 每一项都是幂等的：迁完之后再跑一遍不会有任何动作。
enum StorageMigration {
    /// 现在还在用的缓存子目录。不在这张表里的都是过去某个版本留下的。
    private static let liveCacheKinds: Set<String> = [
        "pool", "labels", "sync", "thread", "message", "inline",
    ]

    static func run(accounts: [String]) {
        renameAccountDirectories(accounts)
        renameTokenFiles(accounts)
        renameAvatarFiles(accounts)
        removeLegacyCacheKinds()
        removeOrphanCacheDirectories(accounts)
    }

    // MARK: - 目录/文件改名（旧格式 → 带摘要的新格式）

    /// 缓存目录 `<sanitize(email)>` → `<sanitize(email)-摘要>`。
    ///
    /// 只在新名字还不存在时才搬，免得两个撞车的旧账号互相覆盖——真撞上了
    /// 就把旧的留在原地，宁可多占一点磁盘，也不能让 A 的邮件出现在 B 名下。
    private static func renameAccountDirectories(_ accounts: [String]) {
        let fm = FileManager.default
        for email in accounts {
            let old = cacheRoot.appendingPathComponent(StorageKey.legacyAccount(email), isDirectory: true)
            let new = cacheRoot.appendingPathComponent(StorageKey.account(email), isDirectory: true)
            guard old != new,
                  fm.fileExists(atPath: old.path),
                  !fm.fileExists(atPath: new.path) else { continue }
            try? fm.moveItem(at: old, to: new)
        }
    }

    /// 令牌文件 `<sanitize(email)>.token` → `<sanitize(email)-摘要>.token`。
    private static func renameTokenFiles(_ accounts: [String]) {
        let fm = FileManager.default
        for email in accounts {
            let old = TokenStore.tokensDirectory
                .appendingPathComponent(StorageKey.legacyAccount(email) + ".token")
            let new = TokenStore.fileURL(for: email)
            guard old != new,
                  fm.fileExists(atPath: old.path),
                  !fm.fileExists(atPath: new.path) else { continue }
            try? fm.moveItem(at: old, to: new)
        }
    }

    /// 头像文件 `<sanitize(email)>.png` → `<sanitize(email)-摘要>.png`。
    /// 不搬的话头像会集体消失，而它只在登录那一刻下载，不重新登录就补不回来。
    private static func renameAvatarFiles(_ accounts: [String]) {
        let fm = FileManager.default
        for email in accounts {
            let old = AvatarStore.directory
                .appendingPathComponent(StorageKey.legacyAccount(email) + ".png")
            let new = AvatarStore.fileURL(for: email)
            guard old != new,
                  fm.fileExists(atPath: old.path),
                  !fm.fileExists(atPath: new.path) else { continue }
            try? fm.moveItem(at: old, to: new)
        }
    }

    // MARK: - 清理

    /// 删掉早期按邮箱存列表快照时留下的 `list/`、`listmeta/`。
    ///
    /// 邮件改成按账户存一份池子之后，这两个目录就再没有代码读写过，
    /// 却会一直躺在那儿——不清理的话，它们是永远不会被谁想起来的死数据。
    private static func removeLegacyCacheKinds() {
        let fm = FileManager.default
        guard let accountDirs = try? fm.contentsOfDirectory(at: cacheRoot,
                                                            includingPropertiesForKeys: nil) else { return }
        for dir in accountDirs {
            guard let kinds = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for kind in kinds where !liveCacheKinds.contains(kind.lastPathComponent) {
                try? fm.removeItem(at: kind)
            }
        }
    }

    /// 删掉不属于任何在册账号的缓存目录。
    ///
    /// 早期把跨账号聚合视图也当成一个「账号」存过（目录名 `__all__`），
    /// 那份数据现在既没人读，删账号时也扫不到——只能在这里按名单反查。
    private static func removeOrphanCacheDirectories(_ accounts: [String]) {
        let fm = FileManager.default
        // 名单为空时不动手：那多半是配置还没读出来，不是真的一个账号都没有
        guard !accounts.isEmpty else { return }
        let known = Set(accounts.map { StorageKey.account($0) })
            .union(accounts.map { StorageKey.legacyAccount($0) })
        guard let dirs = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for dir in dirs where !known.contains(dir.lastPathComponent) {
            try? fm.removeItem(at: dir)
        }
    }

    private static var cacheRoot: URL {
        GoogleConfig.supportDirectory.appendingPathComponent("Cache", isDirectory: true)
    }
}
