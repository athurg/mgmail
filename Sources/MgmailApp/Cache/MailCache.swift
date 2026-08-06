import Foundation
import CryptoKit

/// 缓存的会话正文（渲染后，含内联图片 data URI）。
///
/// 只存正文——那是不可变的，存下来就一直有效。读没读、有没有星标这些属性
/// 全在 `MailStore` 的账户池里，不在这儿留副本，也就不会不一致。
struct CachedThread: Codable {
    let subject: String
    let messages: [RenderedMessage]
}


/// 磁盘 JSON 缓存：标签 / 会话列表摘要 / 会话正文，按账户分目录。
/// 用 actor 把文件读写放到主线程外，并串行化访问。
actor MailCache {
    static let shared = MailCache()

    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        root = GoogleConfig.supportDirectory.appendingPathComponent("Cache", isDirectory: true)
    }

    // MARK: - 标签

    func labels(account: String) -> [GmailLabel]? {
        load([GmailLabel].self, account: account, kind: "labels", key: "labels")
    }
    func saveLabels(_ labels: [GmailLabel], account: String) {
        save(labels, account: account, kind: "labels", key: "labels")
    }

    // MARK: - 增量同步位点

    /// 上次同步到的 historyId。下次从这里继续拉变化。
    func historyID(account: String) -> String? {
        load(String.self, account: account, kind: "sync", key: "historyId")
    }
    func saveHistoryID(_ id: String, account: String) {
        save(id, account: account, kind: "sync", key: "historyId")
    }

    // MARK: - 账户邮件池（全应用唯一的一份邮件数据）

    func pool(account: String) -> AccountPool? {
        load(AccountPool.self, account: account, kind: "pool", key: "pool")
    }
    func savePool(_ pool: AccountPool, account: String) {
        save(pool, account: account, kind: "pool", key: "pool")
    }

    // MARK: - 会话正文

    /// `conversation == false` 时存的是单封邮件（消息 id 与会话 id 可能相同，必须分目录）。
    func thread(account: String, threadID: String, conversation: Bool = true) -> CachedThread? {
        load(CachedThread.self, account: account, kind: conversation ? "thread" : "message", key: threadID)
    }
    func saveThread(_ thread: CachedThread, account: String, threadID: String, conversation: Bool = true) {
        save(thread, account: account, kind: conversation ? "thread" : "message", key: threadID)
    }

    // MARK: - 内联图片（data URI，按 消息+附件 id 缓存，内容不变可长期复用）

    func inlineDataURI(account: String, key: String) -> String? {
        let url = accountDir(account).appendingPathComponent("inline", isDirectory: true)
            .appendingPathComponent(inlineFileName(key))
        guard let data = try? Data(contentsOf: url) else { return nil }
        touch(url)
        return String(data: data, encoding: .utf8)
    }

    func saveInlineDataURI(_ uri: String, account: String, key: String) {
        let dir = accountDir(account).appendingPathComponent("inline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(inlineFileName(key))
        try? Data(uri.utf8).write(to: url, options: .atomic)
    }

    /// attachmentId 很长，会超出文件名长度上限；用 key 的 SHA256 哈希做定长文件名。
    private func inlineFileName(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".datauri"
    }

    // MARK: - 清理

    func clear(account: String) {
        try? FileManager.default.removeItem(at: accountDir(account))
    }

    /// 正文缓存的回收上限。
    ///
    /// 池子（`pool`/`labels`/`sync`）不参与回收：那是同步位点和列表本身，丢了要重新全量拉。
    /// 会回收的是正文与内联图——它们只是「省一次请求」，删掉最多是下次打开慢一点。
    static let bodyCacheLimit = 200 * 1024 * 1024
    /// 多久没打开过就可以丢。
    static let bodyCacheMaxAge: TimeInterval = 120 * 24 * 3600

    /// 按「最后一次用到」回收正文缓存：先丢太久没碰的，还超量就从最旧的接着丢。
    ///
    /// 这份缓存原本只增不减——正文是不可变的，所以一封信只拉一次、存下来就一直留着，
    /// 唯一的清理时机是删账号。日积月累下来它会安静地涨到几百 MB，
    /// 而其中绝大多数是再也不会打开第二次的旧邮件。
    func reclaim() {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }

        var files: [(url: URL, size: Int, used: Date)] = []
        for account in accounts {
            for kind in ["thread", "message", "inline"] {
                let dir = account.appendingPathComponent(kind, isDirectory: true)
                let found = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                for url in found {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    files.append((url,
                                  values?.fileSize ?? 0,
                                  values?.contentModificationDate ?? .distantPast))
                }
            }
        }

        // 老的排在前面，先出局
        files.sort { $0.used < $1.used }
        var total = files.reduce(0) { $0 + $1.size }
        let cutoff = Date().addingTimeInterval(-Self.bodyCacheMaxAge)

        for file in files {
            let tooOld = file.used < cutoff
            let overLimit = total > Self.bodyCacheLimit
            guard tooOld || overLimit else { break }   // 排过序，后面的只会更新更小
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }

    // MARK: - 底层文件读写

    private func load<T: Decodable>(_ type: T.Type, account: String, kind: String, key: String) -> T? {
        let url = fileURL(account: account, kind: kind, key: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        touch(url)
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, account: String, kind: String, key: String) {
        let dir = accountDir(account).appendingPathComponent(kind, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(StorageKey.sanitize(key) + ".json")
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 把文件的修改时间推到此刻，好让回收时能按「最后一次用到」排序。
    ///
    /// 读取本身不改 mtime，不 touch 的话一封天天在看的邮件和一封再没打开过的，
    /// 在回收器眼里一样老。
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func accountDir(_ account: String) -> URL {
        root.appendingPathComponent(StorageKey.account(account), isDirectory: true)
    }

    private func fileURL(account: String, kind: String, key: String) -> URL {
        accountDir(account)
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(StorageKey.sanitize(key) + ".json")
    }
}
