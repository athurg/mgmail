import SwiftUI

/// 网络活动的类别。日志窗口按它筛选，界面按它取图标。
enum ActivityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sync
    case list
    case message
    case modify
    case send
    case label
    case attachment
    case auth
    case profile
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sync: return "同步"
        case .list: return "邮件列表"
        case .message: return "邮件内容"
        case .modify: return "邮件操作"
        case .send: return "发信"
        case .label: return "标签"
        case .attachment: return "附件"
        case .auth: return "授权"
        case .profile: return "账户资料"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .sync: return "arrow.triangle.2.circlepath"
        case .list: return "list.bullet"
        case .message: return "envelope"
        case .modify: return "pencil"
        case .send: return "paperplane"
        case .label: return "tag"
        case .attachment: return "paperclip"
        case .auth: return "key"
        case .profile: return "person.crop.circle"
        case .other: return "network"
        }
    }
}

/// 一条网络活动记录：一次 HTTP 往返，加上它是「在替谁做什么」。
///
/// 记录的粒度刻意就是一次请求——聚合成「一次刷新」看着舒服，
/// 但排查问题时想知道的恰恰是哪一个请求慢了、哪一个被限流了。
struct ActivityEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// 归属账号（邮箱）。登录尚未拿到邮箱时为 nil。
    let account: String?
    let kind: ActivityKind
    /// 人话描述，如「检查新邮件」「获取邮件列表（收件箱）」。
    let title: String
    let method: String
    let url: String
    let startedAt: Date
    var finishedAt: Date?
    var statusCode: Int?
    /// 响应体字节数。
    var bytes: Int = 0
    var errorText: String?
    /// 因限流/服务端抖动重试了几次。
    var retries: Int = 0

    var isRunning: Bool { finishedAt == nil }
    var isFailure: Bool { errorText != nil }
    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    /// 状态列文案。
    var statusText: String {
        if isRunning { return "进行中" }
        if isFailure { return statusCode.map { "失败 \($0)" } ?? "失败" }
        return statusCode.map { "成功 \($0)" } ?? "成功"
    }
}

/// `begin` 返回的句柄，结束时凭它回填结果。
struct ActivityToken: Sendable {
    let id: UUID
    let account: String?
}

/// 全应用的网络活动日志。
///
/// 所有联网出口（Gmail 请求、批量请求、OAuth、头像下载）都在这里登记，
/// 底部活动栏看 `running`，活动窗口看 `entries`，落盘由 `ActivityLogFile` 负责。
///
/// 侧栏的忙碌转圈不订阅这个对象——它变得太频繁。那件事由 `NetworkActivity` 承担，
/// 只在账号忙/闲翻转时才发布，这里顺手驱动它。
@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    /// 全部记录，按开始顺序（老的在前）。
    @Published private(set) var entries: [ActivityEntry] = []
    /// 进行中的活动，先开始的在前。
    @Published private(set) var running: [ActivityEntry] = []
    /// 最近一次失败（底部栏据此提示）。
    @Published private(set) var lastFailure: ActivityEntry?

    /// 内存里最多留多少条；更早的只在磁盘日志里。
    static let capacity = 1000

    private init() {
        Task { [weak self] in
            let restored = await ActivityLogFile.shared.loadRecent(limit: Self.capacity)
            guard let self, !restored.isEmpty else { return }
            // 恢复的历史排在本次会话的记录之前
            self.entries.insert(contentsOf: restored, at: 0)
            self.trim()
        }
        Task { await ActivityLogFile.shared.purge(keepingDays: 7) }
    }

    // MARK: - 记录

    func begin(_ descriptor: ActivityDescriptor, account: String?,
               method: String, url: URL) -> ActivityToken {
        let entry = ActivityEntry(id: UUID(), account: account, kind: descriptor.kind,
                                  title: descriptor.title, method: method,
                                  url: url.absoluteString, startedAt: Date())
        entries.append(entry)
        running.append(entry)
        trim()
        if let account { NetworkActivity.shared.begin(account) }
        return ActivityToken(id: entry.id, account: account)
    }

    /// 被限流/服务端抖动挡回来，正在退避重试。
    func retried(_ token: ActivityToken) {
        update(token) { $0.retries += 1 }
    }

    /// 请求结束（成功或失败）。`error` 非 nil 即为失败。
    func finish(_ token: ActivityToken, statusCode: Int?, bytes: Int = 0, error: String? = nil) {
        var done: ActivityEntry?
        update(token) {
            $0.finishedAt = Date()
            $0.statusCode = statusCode
            $0.bytes = bytes
            $0.errorText = error
            done = $0
        }
        running.removeAll { $0.id == token.id }
        if let account = token.account { NetworkActivity.shared.end(account) }
        guard let done else { return }
        if done.isFailure { lastFailure = done }
        Task { await ActivityLogFile.shared.append(done) }
    }

    /// 清空内存中的记录（磁盘日志不动）。进行中的保留。
    func clear() {
        entries = running
        lastFailure = nil
    }

    /// 把错误转成一行说明。Gmail 的错误体可能很长（整段 JSON），截断存。
    nonisolated static func message(for error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    // MARK: - 内部

    /// 就地改一条记录。进行中的条目总在数组尾部，从后往前找命中很快。
    private func update(_ token: ActivityToken, _ change: (inout ActivityEntry) -> Void) {
        guard let idx = entries.lastIndex(where: { $0.id == token.id }) else { return }
        change(&entries[idx])
        if let r = running.lastIndex(where: { $0.id == token.id }) {
            running[r] = entries[idx]
        }
    }

    /// 超出容量时丢掉最老的，但只丢已经结束的。
    ///
    /// 进行中的条目通常在尾部，可一个慢请求（下载大附件）后面涌进上千条时它就成了最老的那批。
    /// 被裁掉之后 `finish` 的回填便找不着它，那次请求的结果无声无息地消失在日志里。
    private func trim() {
        guard entries.count > Self.capacity else { return }
        var remaining = entries.count - Self.capacity
        entries.removeAll { entry in
            guard remaining > 0, !entry.isRunning else { return false }
            remaining -= 1
            return true
        }
    }
}
