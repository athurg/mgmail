import AppKit
import UserNotifications

/// 新邮件通知的投递中枢：过滤、合并、去重、投递，以及 Dock 角标。
///
/// 唯一的入口是 `enqueue`，由同步管线在**取回信头之后**调用——通知内容要的
/// 发件人和主题就在那批 metadata 里，不必为了弹一条横幅再发一次请求。
///
/// 不直接投递而是先攒一小会儿：一次同步可能带回几十封邮件（关了一夜再打开就是
/// 这个场面），逐条弹出来是灾难。攒够一个合并窗口再决定是逐条报还是报个总数。
@MainActor
final class NewMailNotifier {
    static let shared = NewMailNotifier()

    /// 账号显示名的解析（由 App 层注入 `AppState` 的映射）。汇总通知里要用。
    var accountName: (String) -> String = { $0 }

    /// 攒在合并窗口里、还没投递的新邮件。
    private var pending: [(account: String, message: PooledMessage)] = []
    /// 本轮合并窗口的起点，用来兜住「一直有新邮件进来导致永远不投递」。
    private var windowStart: Date?
    private var flushTask: Task<Void, Never>?

    /// 已经通知过的邮件 id。定时同步、手动刷新、发信后催同步这几个触发点可能撞车，
    /// 位点虽然会推进，但重试路径上仍有可能把同一封邮件带回来两次。
    private var notified: Set<String> = []
    /// 与 `notified` 同步维护的插入顺序，用来把集合裁在上限之内。
    private var notifiedOrder: [String] = []
    private static let notifiedLimit = 500

    /// 合并窗口：最后一封新邮件到达之后再等这么久，期间来的并成一批。
    private static let mergeWindow: Duration = .milliseconds(600)
    /// 合并窗口的硬上限：从第一封算起最多攒这么久，避免持续来信时一直不投递。
    private static let mergeDeadline: TimeInterval = 3

    /// 超过这个条数就不逐条报了，报个总数。
    private static let digestThreshold = 3

    private init() {}

    // MARK: - 入口

    /// 收下一批刚同步回来的新邮件。过滤和去重在这里做，投递推迟到合并窗口结束。
    func enqueue(_ messages: [PooledMessage], account: String) {
        guard NotifyPolicy.enabled, !NotifyPolicy.isMuted(account) else { return }
        let fresh = messages.filter { NotifyPolicy.shouldNotify($0) && !notified.contains($0.id) }
        guard !fresh.isEmpty else { return }

        for message in fresh {
            markNotified(message.id)
            pending.append((account, message))
        }

        // 攒得太久了就别再等了，直接投递这一批
        if let start = windowStart, Date().timeIntervalSince(start) >= Self.mergeDeadline {
            flushNow()
            return
        }
        if windowStart == nil { windowStart = Date() }
        scheduleFlush()
    }

    /// 更新 Dock 角标。`count` 为 0 时清掉。
    ///
    /// 不依赖通知授权——角标是自家进程的事，所以用户拒绝了通知权限时，
    /// 这仍然是能用的那一半。
    func updateBadge(_ count: Int) {
        guard NotifyPolicy.dockBadge else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - 合并窗口

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mergeWindow)
            guard !Task.isCancelled else { return }
            self?.flushNow()
        }
    }

    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        windowStart = nil
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }

        if batch.count <= Self.digestThreshold {
            for item in batch { deliver(item.message, account: item.account) }
        } else {
            deliverDigest(batch)
        }
    }

    // MARK: - 投递

    private func deliver(_ message: PooledMessage, account: String) {
        let content = UNMutableNotificationContent()
        // 和 Apple Mail 同一套版面：谁来的、什么事、说了什么。
        // 账号不占版面——多账号的信息放进 userInfo，点开自然会落到对的地方。
        content.title = message.from
        content.subtitle = message.subject
        content.body = message.snippet
        content.userInfo = NotificationRoute(account: account,
                                             messageID: message.id,
                                             threadID: message.threadId).userInfo
        // 同一个账号的通知在通知中心里归成一组
        content.threadIdentifier = account
        if NotifyPolicy.sound { content.sound = .default }
        submit(content, id: "mail.\(account).\(message.id)")
    }

    /// 一批邮件报一条总数。关了一夜再打开就是这条。
    private func deliverDigest(_ batch: [(account: String, message: PooledMessage)]) {
        let content = UNMutableNotificationContent()
        content.title = "\(batch.count) 封新邮件"
        content.body = digestBody(batch)
        // 落点取第一封：点开至少能到对的账号、对的邮箱
        if let first = batch.first {
            content.userInfo = NotificationRoute(account: first.account,
                                                 messageID: nil,
                                                 threadID: nil).userInfo
        }
        if NotifyPolicy.sound { content.sound = .default }
        submit(content, id: "mail.digest.\(UUID().uuidString)")
    }

    /// 汇总正文：单账号时列发件人，多账号时按账号列条数。
    private func digestBody(_ batch: [(account: String, message: PooledMessage)]) -> String {
        let accounts = Set(batch.map(\.account))
        if accounts.count > 1 {
            return accounts.sorted().map { account in
                let count = batch.filter { $0.account == account }.count
                return "\(accountName(account))：\(count) 封"
            }.joined(separator: "，")
        }
        // 同一个人连发几封时不要把名字重复列出来
        var senders: [String] = []
        for item in batch where !senders.contains(item.message.from) {
            senders.append(item.message.from)
        }
        let shown = senders.prefix(3).joined(separator: "、")
        return senders.count > 3 ? "来自 \(shown) 等 \(senders.count) 人" : "来自 \(shown)"
    }

    private func submit(_ content: UNMutableNotificationContent, id: String) {
        guard NotificationPermission.isAvailable else { return }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor in NotificationPermission.shared.recordDeliveryFailure(error) }
        }
    }

    // MARK: - 去重

    private func markNotified(_ id: String) {
        guard notified.insert(id).inserted else { return }
        notifiedOrder.append(id)
        guard notifiedOrder.count > Self.notifiedLimit else { return }
        let drop = notifiedOrder.count - Self.notifiedLimit
        for old in notifiedOrder.prefix(drop) { notified.remove(old) }
        notifiedOrder.removeFirst(drop)
    }
}

/// 通知点击后要落到哪封邮件。编进 `userInfo`，点开时再解出来。
struct NotificationRoute: Equatable {
    let account: String
    /// 汇总通知没有具体邮件，只落到账号的收件箱。
    let messageID: String?
    let threadID: String?

    var userInfo: [String: Any] {
        var info: [String: Any] = ["account": account]
        if let messageID { info["messageID"] = messageID }
        if let threadID { info["threadID"] = threadID }
        return info
    }

    init(account: String, messageID: String?, threadID: String?) {
        self.account = account
        self.messageID = messageID
        self.threadID = threadID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let account = userInfo["account"] as? String else { return nil }
        self.account = account
        messageID = userInfo["messageID"] as? String
        threadID = userInfo["threadID"] as? String
    }
}
