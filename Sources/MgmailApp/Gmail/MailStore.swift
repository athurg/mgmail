import SwiftUI

/// 池子里的一封邮件：列表显示要用的信息，加上它的标签集合。
///
/// `labelIds` 是全应用**唯一**的邮件属性来源——在哪个邮箱、读没读、有没有星标，
/// 在 Gmail 里全都是标签，所以不再有第二处副本需要同步。
struct PooledMessage: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    var from: String
    var subject: String
    var snippet: String
    var date: Date?
    var hasAttachment: Bool
    var labelIds: [String]

    var isUnread: Bool { labelIds.contains("UNREAD") }
    var isStarred: Bool { labelIds.contains("STARRED") }

    init(_ message: GmailMessage) {
        id = message.id
        threadId = message.threadId ?? message.id
        from = MimeParser.header(message.payload, "From")
            .map { EmailAddress(header: $0).display } ?? "（未知发件人）"
        subject = MimeParser.header(message.payload, "Subject") ?? "（无主题）"
        snippet = message.snippet ?? ""
        date = message.date
        hasAttachment = !MimeParser.attachments(message.payload, messageID: message.id).isEmpty
        labelIds = message.labelIds ?? []
    }
}

/// 一条拉取线翻到哪了。
struct PoolCursor: Codable {
    var pageToken: String?
    /// 服务器上已经没有更多了（区别于「拉到回溯边界，主动停下」）。
    var noMore = false
    /// 这条线累计拉进来多少封，用来对照设置里的回溯上限。
    var fetched = 0
    /// 上次是因为撞到「回溯时间」停的，值为当时的天数设置。
    ///
    /// 必须记下来：时间边界是**整页收下之后**才发现越过的，不记的话每次刷新都会
    /// 为了重新发现这件事而多拉一页——定时刷新每分钟一次，那就是每分钟白拉一页。
    /// 只有把天数调得更长，才需要接着往前拉。
    var stoppedAtDays: Int?
}

/// 一个账户的本地邮件池。
///
/// 池子只增不减：回溯范围管的是「往前拉到哪」，而新邮件由同步不断加进来，
/// 所以实际条数会慢慢超过设置里的上限。这是有意的——把用户看过的邮件裁掉，
/// 比多占几百 KB 磁盘更让人困惑。一条 metadata 约 250 字节，一年下来也就 1MB 上下。
struct AccountPool: Codable {
    var messages: [String: PooledMessage] = [:]
    /// 各拉取线的游标。`""` 是账户主线；`"SPAM"` / `"TRASH"` 是两条特例线，
    /// 因为 Gmail 的列表接口默认不返回这两个邮箱的邮件，只能单独去要。
    var cursors: [String: PoolCursor] = [:]

    /// 池子里最早那封邮件的时间（界面上显示「已回溯至」）。
    ///
    /// 存下来而不是每次现算：侧栏每个账号都要读它，而视图重绘远比数据变化频繁，
    /// 现算就是每次重绘都把近千封邮件扫一遍。
    private(set) var oldestDate: Date?

    mutating func refreshOldest() {
        oldestDate = messages.values.compactMap(\.date).min()
    }
}

/// 回溯范围：拉多少封、拉到多早为止，两个条件谁先到就停在哪。
enum BackfillPolicy {
    static var messageLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.backfillLimit)
        return stored > 0 ? stored : 500
    }

    static var days: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.backfillDays)
        return stored > 0 ? stored : 90
    }

    static var cutoffDate: Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
    }

    /// 每次向 Gmail 要一页的条数。batch 一次也是这个量级，太大响应会很沉。
    static let pageSize = 100
}

/// 账户级的本地邮件池。
///
/// 全应用的邮件数据只有这一份：所有邮箱视图都是对它的本地过滤，切邮箱不发请求。
/// 之所以按账户而不是按邮箱组织，是因为取数的两个源头本来就是账户级的——
/// `history.list` 返回整个账户的变化，`labels.list` 返回整个账户的标签，
/// 而「哪个邮箱」只是每封邮件 `labelIds` 上的一个值。
@MainActor
final class MailStore: ObservableObject {
    /// 池子内容的版本号。视图订阅它来决定什么时候重算列表，
    /// 比订阅整个字典便宜，也避免拿着一份过期快照。
    @Published private(set) var revision = 0 {
        // 未读数只可能随池子变化，所以搭在这里，不必让外面记着去更新角标
        didSet { scheduleBadgeUpdate() }
    }
    /// 最近一次失败（界面提示用）。
    @Published var lastError: String?

    /// 正在跑增量同步的账户，防止定时和手动撞到一起重复拉。
    /// 界面上的「忙碌中」不看这个——那由 `NetworkActivity` 统一负责，它覆盖所有请求。
    private var syncing: Set<String> = []
    private var pools: [String: AccountPool] = [:]
    private var persistTasks: [String: Task<Void, Never>] = [:]
    private var badgeTask: Task<Void, Never>?

    // MARK: - 读

    func messages(account: String) -> [PooledMessage] {
        Array(pools[account]?.messages.values ?? [:].values)
    }

    func message(account: String, id: String) -> PooledMessage? {
        pools[account]?.messages[id]
    }

    /// 某个会话在池子里的全部邮件（按时间正序）。
    func threadMessages(account: String, threadID: String) -> [PooledMessage] {
        (pools[account]?.messages.values ?? [:].values)
            .filter { $0.threadId == threadID }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// 一个会话（或单封）当前的标签并集——详情栏的按钮状态由它决定。
    func labels(account: String, threadID: String, conversation: Bool) -> Set<String> {
        if conversation {
            return Set(threadMessages(account: account, threadID: threadID).flatMap(\.labelIds))
        }
        return Set(pools[account]?.messages[threadID]?.labelIds ?? [])
    }

    /// 池子回溯到的最早时间（侧栏账号下面显示）。
    func oldestDate(account: String) -> Date? {
        pools[account]?.oldestDate
    }

    func isEmpty(account: String) -> Bool {
        pools[account]?.messages.isEmpty ?? true
    }

    // MARK: - 冷启动

    /// 从磁盘恢复各账户的池子。不联网。
    func restore(accounts: [String]) async {
        for account in accounts where pools[account] == nil {
            if var pool = await MailCache.shared.pool(account: account) {
                pool.refreshOldest() // 存盘的可能是没有这个字段的旧格式，恢复后现算一次
                pools[account] = pool
            }
        }
        revision += 1
    }

    // MARK: - 刷新（冷启动 / 定时 / 手动，三个时机共用这一个入口）

    /// 同步一个账户：先按位点拉变化，再把回溯范围补齐。
    func refresh(account: String) async {
        guard !syncing.contains(account) else { return }
        syncing.insert(account)
        defer { syncing.remove(account) }

        // 池子还没建起来时没有「变化」可言，直接进回溯
        if pools[account]?.cursors[""] != nil {
            let outcome = await MailSync.incremental(account: account)
            if outcome.needsFullReload {
                // 位点太旧（Gmail 只留约一周），增量已经接不上，池子重建
                pools[account] = AccountPool()
                revision += 1
            } else {
                apply(outcome, to: account)
                await fetchNew(outcome.added, account: account)
            }
        }
        await backfill(account: account, scope: nil)
        persist(account)
    }

    /// 垃圾邮件 / 废纸篓：Gmail 默认不返回它们，点进去时才单独拉。
    ///
    /// 走的是自己那条线，和主线互不干扰，所以不必等主线的同步让路。
    func ensureMailbox(account: String, labelID: String) async {
        guard MailboxQuery.needsExplicitFetch(labelID: labelID) else { return }
        guard pools[account]?.cursors[labelID] == nil else { return } // 拉过了
        await backfill(account: account, scope: labelID)
        persist(account)
    }

    // MARK: - 回溯拉取

    /// 沿一条拉取线往前翻，直到够了设置里的条数、翻过了设置里的时间，或者服务器没有更多。
    private func backfill(account: String, scope: String?) async {
        let key = scope ?? ""
        var cursor = pools[account]?.cursors[key] ?? PoolCursor()
        guard !cursor.noMore else { return }

        let limit = BackfillPolicy.messageLimit
        let days = BackfillPolicy.days
        let cutoff = BackfillPolicy.cutoffDate
        // 上次就是因为时间到边界停的，而边界没放宽——没有什么可拉的了
        if let stopped = cursor.stoppedAtDays, stopped >= days { return }
        let api = GmailAPI(account: account)

        while cursor.fetched < limit {
            do {
                let want = min(BackfillPolicy.pageSize, limit - cursor.fetched)
                let list = try await api.listMessages(labelId: scope, query: nil,
                                                      pageToken: cursor.pageToken,
                                                      maxResults: want,
                                                      includeSpamTrash: scope != nil)
                let refs = list.messages ?? []
                if refs.isEmpty {
                    cursor.noMore = true
                    break
                }

                let fetched = await fetchMetadata(refs.map(\.id), api: api)
                merge(fetched, into: account)
                cursor.fetched += fetched.count
                cursor.pageToken = list.nextPageToken
                // 每页都记下来：中途失败或退出，已经拉到的不白费
                setCursor(cursor, key: key, account: account)

                if list.nextPageToken == nil {
                    cursor.noMore = true
                    break
                }
                // 翻到比回溯时间更早的邮件了，停在这（这一页整体收下，不再往前）
                if let oldest = fetched.compactMap(\.date).min(), oldest < cutoff {
                    cursor.stoppedAtDays = days
                    break
                }
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                break
            }
        }
        setCursor(cursor, key: key, account: account)
        // 首次拉完顺手记下同步位点，之后的变化就都走增量了
        await MailSync.captureStartPointIfNeeded(account: account)
    }

    /// 一次 batch 把整页的 metadata 取回来：一页 100 封是 1 个请求，不是 100 个。
    private func fetchMetadata(_ ids: [String], api: GmailAPI) async -> [PooledMessage] {
        guard !ids.isEmpty else { return [] }
        let items = ids.map {
            BatchItem(id: $0, path: "/messages/\($0)", query: Self.metadataQuery)
        }
        guard let responses = try? await api.batchGet(items) else { return [] }
        return ids.compactMap { id in
            guard let result = responses[id], result.isSuccess,
                  let message = try? JSONDecoder().decode(GmailMessage.self, from: result.body)
            else { return nil }
            return PooledMessage(message)
        }
    }

    private static let metadataQuery: [URLQueryItem] = {
        var query = [URLQueryItem(name: "format", value: "metadata")]
        for header in ["From", "To", "Subject", "Date"] {
            query.append(URLQueryItem(name: "metadataHeaders", value: header))
        }
        return query
    }()

    // MARK: - 增量同步的落地

    /// history 已经告诉了我们变动的是哪几个标签，本地按增删应用即可，不必回头逐封去问。
    private func apply(_ outcome: SyncOutcome, to account: String) {
        guard var pool = pools[account] else { return }
        for id in outcome.removed {
            pool.messages.removeValue(forKey: id)
        }
        if !outcome.removed.isEmpty { pool.refreshOldest() }
        for (id, delta) in outcome.labelChanges {
            guard var message = pool.messages[id] else { continue } // 不在回溯范围内，不关心
            var labels = Set(message.labelIds)
            labels.formUnion(delta.add)
            labels.subtract(delta.remove)
            message.labelIds = labels.sorted()
            pool.messages[id] = message
        }
        pools[account] = pool
        revision += 1
    }

    /// 新到的邮件 history 只给了 id，得把信头取回来才能显示。
    ///
    /// 这里也是新邮件通知唯一的来源：`added` 只装 `history.messagesAdded`，
    /// 回溯拉取走的是 `merge` 那条线，所以首次同步几百封不会变成几百条通知。
    /// 通知内容要的发件人和主题就在这批 metadata 里，不必再发一次请求。
    private func fetchNew(_ added: [String: String], account: String) async {
        let ids = added.keys.filter { pools[account]?.messages[$0] == nil }
        guard !ids.isEmpty else { return }
        let fresh = await fetchMetadata(Array(ids), api: GmailAPI(account: account))
        merge(fresh, into: account)
        NewMailNotifier.shared.enqueue(fresh, account: account)
    }

    /// 拿服务器状态纠正几封邮件（本地改标签失败时用）。
    func revalidate(account: String, messageIDs: [String]) async {
        guard !messageIDs.isEmpty else { return }
        let fresh = await fetchMetadata(messageIDs, api: GmailAPI(account: account))
        merge(fresh, into: account)
        persist(account)
    }

    // MARK: - 本地改动（乐观更新）

    /// 按增删改这些邮件的标签。界面立刻响应，请求在外面发。
    func applyLabels(account: String, messageIDs: [String], add: [String], remove: [String]) {
        guard !messageIDs.isEmpty, !add.isEmpty || !remove.isEmpty,
              var pool = pools[account] else { return }
        for id in messageIDs {
            guard var message = pool.messages[id] else { continue }
            var labels = Set(message.labelIds)
            labels.formUnion(add)
            labels.subtract(remove)
            message.labelIds = labels.sorted()
            pool.messages[id] = message
        }
        pools[account] = pool
        revision += 1
        persist(account)
    }

    /// 移入废纸篓：加 TRASH、离开收件箱。
    func applyTrash(account: String, messageIDs: [String]) {
        applyLabels(account: account, messageIDs: messageIDs, add: ["TRASH"], remove: ["INBOX"])
    }

    // MARK: - 内部

    private func merge(_ fresh: [PooledMessage], into account: String) {
        guard !fresh.isEmpty else { return }
        var pool = pools[account] ?? AccountPool()
        for message in fresh {
            pool.messages[message.id] = message
        }
        pool.refreshOldest()
        pools[account] = pool
        revision += 1
    }

    private func setCursor(_ cursor: PoolCursor, key: String, account: String) {
        var pool = pools[account] ?? AccountPool()
        pool.cursors[key] = cursor
        pools[account] = pool
    }

    /// 落盘。合并短时间内的多次改动——连着标记十几封已读不该写十几次文件。
    private func persist(_ account: String) {
        persistTasks[account]?.cancel()
        persistTasks[account] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let pool = self.pools[account] else { return }
            await MailCache.shared.savePool(pool, account: account)
        }
    }

    // MARK: - Dock 角标

    /// 所有账号收件箱里的未读数。
    ///
    /// 不看当前分组——角标是「有没有人找我」，不该因为切了个分组就变。
    /// 被静音的账号不计入：用户说了不想被它打扰，角标也是打扰的一种。
    func unreadInboxCount() -> Int {
        let muted = NotifyPolicy.mutedAccounts
        return pools.reduce(0) { total, entry in
            guard !muted.contains(entry.key) else { return total }
            return total + entry.value.messages.values.filter {
                let labels = Set($0.labelIds)
                return labels.contains("INBOX") && labels.contains("UNREAD")
                    && labels.isDisjoint(with: ["SPAM", "TRASH"])
            }.count
        }
    }

    /// 立刻重算角标（设置里改了开关或静音名单时用）。
    func refreshBadge() {
        NewMailNotifier.shared.updateBadge(unreadInboxCount())
    }

    /// 合并短时间内的多次改动——连着标记十几封已读不该把几千封邮件扫十几遍。
    private func scheduleBadgeUpdate() {
        badgeTask?.cancel()
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.refreshBadge()
        }
    }

    /// 移除某账户的池子（账号被删时）。
    func drop(account: String) {
        pools.removeValue(forKey: account)
        persistTasks.removeValue(forKey: account)?.cancel()
        revision += 1
    }
}

/// 一次刷新要做的两件事，顺序固定：先把标签定义拉新，再按位点同步邮件变化。
///
/// 标签在前，是因为邮件的属性全是标签 id，先有定义后有归属，界面才不会出现
/// 「邮件带着一个还不认识的标签」的中间态。
enum MailRefresh {
    /// `colors` 为 false 时标签只拉列表、不重新问颜色（定时刷新用，见 `LabelStore.load`）。
    @MainActor
    static func account(_ account: String, labels: LabelStore, mail: MailStore,
                        colors: Bool = true) async {
        await labels.load(for: account, force: true, refreshColors: colors)
        await mail.refresh(account: account)
    }

    /// 多个账户并发刷新。并发数由 `RequestGate` 统一压着，不会一下打出去太多请求。
    @MainActor
    static func accounts(_ accounts: [String], labels: LabelStore, mail: MailStore,
                         colors: Bool = true) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { @MainActor in
                    await Self.account(account, labels: labels, mail: mail, colors: colors)
                }
            }
        }
    }
}
