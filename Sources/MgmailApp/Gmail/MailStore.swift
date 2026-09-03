import SwiftUI

/// 池子里的一封邮件：列表显示要用的信息，加上它的标签集合。
///
/// `labelIds` 是全应用**唯一**的邮件属性来源——在哪个邮箱、读没读、有没有星标，
/// 在 Gmail 里全都是标签，所以不再有第二处副本需要同步。
struct PooledMessage: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    var from: String
    /// 发件人地址（`from` 是显示名）。列表上不显示它，是搜索要用——
    /// 「某个域名来的信」是最常用的一种搜法，而显示名里通常根本没有地址。
    var fromEmail: String = ""
    var subject: String
    var snippet: String
    var date: Date?
    var hasAttachment: Bool
    var labelIds: [String]

    /// 折叠好的可搜文本。**不进磁盘**：它是那几个字段的纯函数，读盘时现算一次，
    /// 比让 pool.json 大出一倍、每次启动多解一倍的 JSON 划算。见 `encode(to:)`。
    private(set) var searchText: SearchableText

    var isUnread: Bool { labelIds.contains("UNREAD") }
    var isStarred: Bool { labelIds.contains("STARRED") }

    init(_ message: GmailMessage) {
        id = message.id
        threadId = message.threadId ?? message.id
        let sender = MimeParser.header(message.payload, "From").map { EmailAddress(header: $0) }
        from = sender?.display ?? "（未知发件人）"
        fromEmail = sender?.email ?? ""
        subject = MimeParser.header(message.payload, "Subject") ?? "（无主题）"
        snippet = message.snippet ?? ""
        date = message.date
        hasAttachment = !MimeParser.attachments(message.payload, messageID: message.id).isEmpty
        labelIds = message.labelIds ?? []
        searchText = SearchableText(from: from, fromEmail: fromEmail,
                                    subject: subject, snippet: snippet)
    }

    /// 手写解码，理由和 `AccountPool` 那边一模一样：给邮件加字段时，旧的 pool.json
    /// 仍然读得进来。合成的解码器缺一个键就整份抛错，而池子是嵌在 pool.json 里的
    /// 一个字典——一封邮件解不出来，整个账户的池子就跟着没了。
    ///
    /// 池子只增不减，旧邮件没人会回头重取，所以缺的字段只能就地拿现有的顶上：
    /// `fromEmail` 退回显示名（本来就没有显示名的信，它存的就是地址）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = try c.decode(String.self, forKey: .threadId)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? "（未知发件人）"
        fromEmail = try c.decodeIfPresent(String.self, forKey: .fromEmail) ?? from
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? "（无主题）"
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date)
        hasAttachment = try c.decodeIfPresent(Bool.self, forKey: .hasAttachment) ?? false
        labelIds = try c.decodeIfPresent([String].self, forKey: .labelIds) ?? []
        searchText = SearchableText(from: from, fromEmail: fromEmail,
                                    subject: subject, snippet: snippet)
    }

    /// 手写编码，只为把 `searchText` 挡在磁盘外面。
    ///
    /// 代价是加字段时这里也得记着加一行——漏了就是那个字段永远存不下去。
    /// 换来的是池子的体积和解码时间都不受搜索这件事影响。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(from, forKey: .from)
        try c.encode(fromEmail, forKey: .fromEmail)
        try c.encode(subject, forKey: .subject)
        try c.encode(snippet, forKey: .snippet)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encode(hasAttachment, forKey: .hasAttachment)
        try c.encode(labelIds, forKey: .labelIds)
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadId, from, fromEmail, subject, snippet, date, hasAttachment, labelIds
    }

    /// 参与匹配的东西。搜索本身不认识 `PooledMessage`，见 `MailSearch.swift`。
    var searchable: SearchableMail {
        SearchableMail(text: searchText, labelIds: labelIds, hasAttachment: hasAttachment)
    }
}

extension MailboxQuery {
    /// 这封邮件属不属于该邮箱。判断只看标签，见 `MailboxQuery` 的说明。
    func belongs(_ message: PooledMessage) -> Bool {
        labelsBelong(message.labelIds)
    }
}

extension MailSearchQuery {
    /// 这封邮件命不命中当前的搜索词。
    func matches(_ message: PooledMessage) -> Bool {
        matches(message.searchable)
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

    /// 欠着的信头：知道有这么一封，但还没把它的 metadata 拿回来。
    ///
    /// 两个来源，共同点是「错过这一次就再没有下一次」——池子只增不减，
    /// 回溯又是一条不回头的线，没人会替它们重来：
    /// - 批量取信头时个别子请求失败的。翻页照常往前，这一封就此被跳过。
    /// - 增量同步报告标签变动、但池子里没有的。池外不等于太旧，它可能刚从
    ///   废纸篓被捞回收件箱，也可能当初就是上一种情况漏掉的。
    var pending: Set<String> = []

    /// 欠账的上限。到这个量级说明同步已经出了别的问题，再攒下去只是让
    /// 每轮补取都在原地打转。
    static let pendingLimit = 500

    /// 上次跟服务器核对收件箱的时间。
    private(set) var lastAuditAt: Date?

    /// 用户点过「加载远程内容」的邮件 id。
    ///
    /// 放在池子里而不是视图上，是因为这个决定属于那封信、不属于那次打开：
    /// 一封账单第一次点了加载，隔天再翻出来还得再点一次，是在反复问同一个问题。
    /// 跟标签一样按邮件记、跟池子一起落盘，邮件被彻底删掉时随它一起走。
    var remoteContentAllowed: Set<String> = []

    mutating func markAudited(at date: Date = Date()) {
        lastAuditAt = date
    }

    mutating func refreshOldest() {
        oldestDate = messages.values.compactMap(\.date).min()
    }

    mutating func remember(pending id: String) {
        guard pending.count < Self.pendingLimit else { return }
        pending.insert(id)
    }

    /// 邮件从池子里彻底消失（服务器上被永久删除）时，把它的远程内容记忆也一并清掉。
    ///
    /// 只在这一条路上清：移进废纸篓只是换标签，信还在，用户的选择也还算数。
    mutating func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            messages.removeValue(forKey: id)
        }
        remoteContentAllowed.subtract(ids)
        refreshOldest()
    }
}

extension AccountPool {
    private enum CodingKeys: String, CodingKey {
        case messages, cursors, oldestDate, pending, lastAuditAt, remoteContentAllowed
    }

    /// 手写解码，只为一件事：给池子加字段时，旧的 pool.json 仍然读得进来。
    ///
    /// 合成的解码器对「有默认值但非可选」的字段照样要求键存在，缺一个就整份抛错，
    /// 而这份文件解不出来的后果不是少个字段，是池子被当成空的、整个账户推倒重拉——
    /// 回溯范围之外的邮件就此消失，界面上还什么都不会说。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeIfPresent([String: PooledMessage].self, forKey: .messages) ?? [:]
        cursors = try container.decodeIfPresent([String: PoolCursor].self, forKey: .cursors) ?? [:]
        oldestDate = try container.decodeIfPresent(Date.self, forKey: .oldestDate)
        pending = try container.decodeIfPresent(Set<String>.self, forKey: .pending) ?? []
        lastAuditAt = try container.decodeIfPresent(Date.self, forKey: .lastAuditAt)
        remoteContentAllowed = try container.decodeIfPresent(Set<String>.self, forKey: .remoteContentAllowed) ?? []
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

        var arrived: [PooledMessage] = []
        // 池子还没建起来时没有「变化」可言，直接进回溯
        if pools[account]?.cursors[""] != nil {
            let outcome = await MailSync.incremental(account: account)
            if outcome.needsFullReload {
                // 位点太旧（Gmail 只留约一周），增量已经接不上，池子重建。
                // 远程内容的记忆要带过去：重建丢的是本地副本，信本身还在服务器上，
                // 回溯拉回来之后用户没理由再点一遍。
                var rebuilt = AccountPool()
                rebuilt.remoteContentAllowed = pools[account]?.remoteContentAllowed ?? []
                pools[account] = rebuilt
                revision += 1
            } else {
                apply(outcome, to: account)
                let arrival = await fetchNew(outcome.added, account: account)
                arrived = arrival.fresh
                // 信头确实取回来了才把位点推过去。取不回来就让位点停在原地，
                // 下一轮从同一个起点重来一次——多拉一次总好过邮件永远不出现。
                if arrival.complete {
                    await MailSync.commit(outcome, account: account)
                }
            }
        }
        await resolvePending(account: account)
        await backfill(account: account, scope: nil)
        await auditInbox(account: account)
        persist(account)
        // 正文预取排在最后，也只排在最后：它是「打开时不用等」的提前量，
        // 位点、欠账、对账这些关乎邮件会不会丢的事一件都不该等它。
        await BodyPrefetch.run(arrived, account: account)
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
        // 位点要在**开拉之前**记下。首次全量是几十秒到几分钟的事，等拉完再记，
        // 这中间到达的邮件就掉进缝里了：列表第一页取的时候它还没到，
        // 而增量的起点又排在它后面，两头都够不着，且再没有人会回头发现它。
        // 位点早一点最多让下一轮重复处理几条，重复无害，漏掉是永久的。
        await MailSync.captureStartPointIfNeeded(account: account)

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

                // 这一页的信头没取回来就停在这儿，游标不动。往前翻的话，
                // 这一页的邮件谁也不会再回来拉一次，等于凭空少掉一页。
                guard let batch = await fetchMetadata(refs.map(\.id), api: api) else {
                    lastError = "同步中断，稍后会自动重试"
                    break
                }
                merge(batch.messages, into: account)
                // 整页失败会停在上面，走到这里说明只是个别子请求没成。那几封同样
                // 没人会再回来拉——记进欠账，交给 `resolvePending` 补。
                remember(pending: batch.failed, account: account)
                // 记「翻过了多少封」，不是「拿到了多少封」：这个数是拿来对照回溯
                // 上限的，漏掉的那几封同样占掉了页面的位置。
                cursor.fetched += refs.count
                cursor.pageToken = list.nextPageToken
                // 每页都记下来：中途失败或退出，已经拉到的不白费
                setCursor(cursor, key: key, account: account)

                if list.nextPageToken == nil {
                    cursor.noMore = true
                    break
                }
                // 翻到比回溯时间更早的邮件了，停在这（这一页整体收下，不再往前）
                if let oldest = batch.messages.compactMap(\.date).min(), oldest < cutoff {
                    cursor.stoppedAtDays = days
                    break
                }
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                break
            }
        }
        setCursor(cursor, key: key, account: account)
    }

    /// 一批信头的取回结果。
    struct MetadataBatch {
        var messages: [PooledMessage] = []
        /// 这一批里没拿回来的：子请求失败，或响应解不出来。整趟请求失败不在此列。
        var failed: [String] = []
        /// 服务器明确说没有这封信（404）。已经不存在的东西不必再欠着。
        var gone: [String] = []
    }

    /// 一次 batch 把整页的 metadata 取回来：一页 100 封是 1 个请求，不是 100 个。
    ///
    /// 返回 nil 表示这一趟请求本身没成功，区别于「成功了但个别子请求失败」。
    /// 三种结果必须分开：整趟失败要让调用方停下重来；个别失败得记下来，
    /// 因为调用方翻过这一页就再也不会回来；只有确实取回来的才算数。
    private func fetchMetadata(_ ids: [String], api: GmailAPI) async -> MetadataBatch? {
        guard !ids.isEmpty else { return MetadataBatch() }
        let items = ids.map {
            BatchItem(id: $0, path: "/messages/\($0)", query: Self.metadataQuery)
        }
        guard let responses = try? await api.batchGet(items) else { return nil }

        var batch = MetadataBatch()
        for id in ids {
            guard let result = responses[id] else {
                batch.failed.append(id)
                continue
            }
            guard result.isSuccess else {
                if result.status == 404 { batch.gone.append(id) } else { batch.failed.append(id) }
                continue
            }
            guard let message = try? JSONDecoder().decode(GmailMessage.self, from: result.body) else {
                batch.failed.append(id)
                continue
            }
            batch.messages.append(PooledMessage(message))
        }
        return batch
    }

    /// 把欠着的信头补回来。每轮同步补一批，取回来的就不欠了。
    ///
    /// 这是池子唯一的「回头路」：其余每条线都是只往前走的——回溯不回头，
    /// 增量只认位点之后的变化。没有这一步，任何一次漏掉都是永久的。
    private func resolvePending(account: String) async {
        guard let owed = pools[account]?.pending, !owed.isEmpty else { return }
        let ids = Array(owed.prefix(GmailAPI.batchLimit))
        guard let batch = await fetchMetadata(ids, api: GmailAPI(account: account)) else { return }

        merge(batch.messages, into: account)
        guard var pool = pools[account] else { return }
        // 拿回来的、以及服务器说没有的，都不必再欠着。剩下的留到下一轮再试。
        pool.pending.subtract(batch.messages.map(\.id))
        pool.pending.subtract(batch.gone)
        pools[account] = pool
    }

    // MARK: - 收件箱对账

    /// 隔多久跟服务器核对一次收件箱。
    private static let auditInterval: TimeInterval = 6 * 3600
    /// 一次对账最多翻几页。翻不完的话只补不删，见 `auditInbox`。
    private static let auditPageLimit = 3

    /// 拿服务器的收件箱跟本地对一遍，对不上的都记进欠账重取。
    ///
    /// 同步的每条线都不回头：回溯翻过的页不会重来，增量只认位点之后的变化，
    /// 于是任何一次漏掉都是永久的——发现的时候只能把整个池子删掉重建。
    /// 漏掉的具体原因可以一个个修，但总还会有下一个：网络抖动、偶发的 5xx、
    /// 某个想不到的边界。所以除了修原因，还得有一条认账的路。
    ///
    /// 只认收件箱：它是唯一「少一封就会被看见」的视图，也是最便宜的对账对象——
    /// 一次 list 只回 id，一页 100 封几 KB，六小时一次可以忽略不计。
    private func auditInbox(account: String) async {
        guard let pool = pools[account], !pool.messages.isEmpty else { return } // 池子还没建起来
        if let last = pool.lastAuditAt, Date().timeIntervalSince(last) < Self.auditInterval { return }

        let api = GmailAPI(account: account)
        var remote: Set<String> = []
        var pageToken: String?
        var complete = false
        for _ in 0 ..< Self.auditPageLimit {
            guard let list = try? await api.listMessages(labelId: "INBOX", query: nil,
                                                         pageToken: pageToken,
                                                         maxResults: BackfillPolicy.pageSize) else {
                return // 这轮没对成就不记时间，下一轮接着来
            }
            remote.formUnion((list.messages ?? []).map(\.id))
            pageToken = list.nextPageToken
            if pageToken == nil {
                complete = true
                break
            }
        }

        let local = Set(messages(account: account).filter { $0.labelIds.contains("INBOX") }.map(\.id))
        // 服务器说在收件箱、本地却不知道的：补。这是对账的主要目的。
        var owed = remote.subtracting(local)
        // 本地以为在收件箱、服务器却没有的：也补，本地的标签多半已经过时了。
        // 只有整个收件箱翻完才敢这么算——翻了一半的话，「不在这几页里」不等于
        // 「不在收件箱里」，照着删会把收件箱清空。
        if complete { owed.formUnion(local.subtracting(remote)) }

        markAudited(account)
        guard !owed.isEmpty else { return }
        // 两边都只有 id，谁对谁错本地判断不了，一律重取信头拿服务器的标签为准
        remember(pending: Array(owed), account: account)
        await resolvePending(account: account)
    }

    private func markAudited(_ account: String) {
        guard var pool = pools[account] else { return }
        pool.markAudited()
        pools[account] = pool
    }

    private func remember(pending ids: [String], account: String) {
        guard !ids.isEmpty else { return }
        var pool = pools[account] ?? AccountPool()
        for id in ids {
            pool.remember(pending: id)
        }
        pools[account] = pool
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
        pool.forget(outcome.removed)
        for (id, delta) in outcome.labelChanges {
            guard var message = pool.messages[id] else {
                // 池外不等于「太旧、不关心」。它可能刚被从废纸篓捞回收件箱，
                // 也可能当初取信头时漏掉了——这两种邮件在服务器上活得好好的，
                // 只是本地不知道。丢掉这条变动，它就再也没有机会出现在列表里。
                //
                // 只有加标签才值得补：纯粹被摘掉标签的邮件，补回来也不属于任何视图。
                if !delta.add.isEmpty { pool.remember(pending: id) }
                continue
            }
            var labels = Set(message.labelIds)
            labels.formUnion(delta.add)
            labels.subtract(delta.remove)
            message.labelIds = labels.sorted()
            pool.messages[id] = message
        }
        pools[account] = pool
        revision += 1
    }

    /// 一批新邮件的落地结果。
    struct Arrival {
        /// 信头是不是确实取回来了——位点要等这个点头才能往前推。
        var complete = true
        /// 真正新到的那几封（池子里原本没有的）。通知和正文预取都只认这一批。
        var fresh: [PooledMessage] = []
    }

    /// 新到的邮件 history 只给了 id，得把信头取回来才能显示。
    ///
    /// 这里也是新邮件通知唯一的来源：`added` 只装 `history.messagesAdded`，
    /// 回溯拉取走的是 `merge` 那条线，所以首次同步几百封不会变成几百条通知。
    /// 通知内容要的发件人和主题就在这批 metadata 里，不必再发一次请求。
    /// 正文预取搭的也是这条线，理由相同：加个账号不该先下几百封正文。
    private func fetchNew(_ added: [String: String], account: String) async -> Arrival {
        let ids = Array(added.keys)
        guard !ids.isEmpty else { return Arrival() }
        // 池子里已经有的也要重取。`MailSync` 把 added 那几封的标签变动删掉了，
        // 理由是「信头会连同最新标签一起回来」——那就不能反过来因为池里已经有它
        // 而跳过取信头，否则这一轮它的标签变动两头都没人管，会一直停在旧值上。
        let known = Set(ids.filter { pools[account]?.messages[$0] != nil })
        guard let batch = await fetchMetadata(ids, api: GmailAPI(account: account)) else {
            return Arrival(complete: false)
        }
        merge(batch.messages, into: account)
        // 个别没取回来的记进欠账，位点就可以照常往前推——不会再有邮件因此消失
        remember(pending: batch.failed, account: account)
        // 只认真正新到的：重取回来的老邮件不该再弹一次通知，正文多半也早就在缓存里
        let fresh = batch.messages.filter { !known.contains($0.id) }
        NewMailNotifier.shared.enqueue(fresh, account: account)
        return Arrival(fresh: fresh)
    }

    /// 拿服务器状态纠正几封邮件（本地改标签失败时用）。
    func revalidate(account: String, messageIDs: [String]) async {
        guard !messageIDs.isEmpty else { return }
        guard let batch = await fetchMetadata(messageIDs, api: GmailAPI(account: account)) else {
            // 整趟请求就没成（断网，或者调用方的任务连着这一趟一起被取消了）。
            // 这几封本地还留着乐观改上去、服务器却没收到的状态，欠着，下一轮同步接着纠——
            // 不记的话没有谁会再回头看它们一眼：服务器上什么都没发生，增量同步不会提，
            // 收件箱对账也只比对邮件在不在收件箱，不比标签。
            remember(pending: messageIDs, account: account)
            persist(account)
            return
        }
        merge(batch.messages, into: account)
        // 纠正失败的那几封本地还留着改坏的状态，欠着，下一轮同步接着纠
        remember(pending: batch.failed, account: account)
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

    // MARK: - 远程内容

    /// 这封信是不是点过「加载远程内容」。
    func allowsRemoteContent(account: String, messageID: String) -> Bool {
        pools[account]?.remoteContentAllowed.contains(messageID) ?? false
    }

    /// 记住这封信允许加载远程内容，以后打开不必再点。
    ///
    /// 不动 `revision`：列表上没有任何东西会因此变化，不值得让它重算一遍。
    /// 正在看的那个视图自己已经切过去了，这里只负责记下来。
    func allowRemoteContent(account: String, messageID: String) {
        var pool = pools[account] ?? AccountPool()
        guard pool.remoteContentAllowed.insert(messageID).inserted else { return }
        pools[account] = pool
        persist(account)
    }

    /// 移入废纸篓：加 TRASH、离开收件箱。
    func applyTrash(account: String, messageIDs: [String]) {
        applyLabels(account: account, messageIDs: messageIDs, add: ["TRASH"], remove: ["INBOX"])
    }

    /// 放回收件箱：加 INBOX，并把 TRASH / SPAM 摘掉——归档的和删掉的都走这一条。
    func applyMoveToInbox(account: String, messageIDs: [String]) {
        applyLabels(account: account, messageIDs: messageIDs,
                    add: MailPlacement.inboxAdd, remove: MailPlacement.inboxRemove + ["TRASH"])
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
