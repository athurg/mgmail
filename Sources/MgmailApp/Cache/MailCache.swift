import Foundation
import CryptoKit

/// 缓存的会话正文（渲染后，含内联图片 data URI），用于打开会话时瞬时显示。
struct CachedThread: Codable {
    let subject: String
    let messages: [RenderedMessage]
    let threadLabelIds: [String]
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

    // MARK: - 会话列表摘要（每个邮箱一份，缓存首屏）

    func summaries(account: String, labelID: String) -> [ThreadSummary]? {
        load([ThreadSummary].self, account: account, kind: "list", key: labelID)
    }
    func saveSummaries(_ summaries: [ThreadSummary], account: String, labelID: String) {
        save(summaries, account: account, kind: "list", key: labelID)
    }

    // MARK: - 会话正文

    func thread(account: String, threadID: String) -> CachedThread? {
        load(CachedThread.self, account: account, kind: "thread", key: threadID)
    }
    func saveThread(_ thread: CachedThread, account: String, threadID: String) {
        save(thread, account: account, kind: "thread", key: threadID)
    }

    // MARK: - 内联图片（data URI，按 消息+附件 id 缓存，内容不变可长期复用）

    func inlineDataURI(account: String, key: String) -> String? {
        let url = accountDir(account).appendingPathComponent("inline", isDirectory: true)
            .appendingPathComponent(inlineFileName(key))
        guard let data = try? Data(contentsOf: url) else { return nil }
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

    // MARK: - 底层文件读写

    private func load<T: Decodable>(_ type: T.Type, account: String, kind: String, key: String) -> T? {
        let url = fileURL(account: account, kind: kind, key: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, account: String, kind: String, key: String) {
        let dir = accountDir(account).appendingPathComponent(kind, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(sanitize(key) + ".json")
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func accountDir(_ account: String) -> URL {
        root.appendingPathComponent(sanitize(account), isDirectory: true)
    }

    private func fileURL(account: String, kind: String, key: String) -> URL {
        accountDir(account)
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(sanitize(key) + ".json")
    }

    /// 把任意字符串转成安全的文件名（保留字母数字，其余换成下划线）。
    private func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "_" : result
    }
}
