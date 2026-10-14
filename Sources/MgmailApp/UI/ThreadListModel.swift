import SwiftUI
import Combine

/// 会话列表中的一行。
///
/// 这是个**派生**出来的东西：由池子里的邮件按当前显示方式算出来，自己不持有任何状态。
struct ThreadSummary: Identifiable, Hashable {
    let id: String
    let from: String
    let subject: String
    let snippet: String
    let date: Date?
    let isUnread: Bool
    let isStarred: Bool
    let hasAttachment: Bool
    let messageCount: Int
    /// 会话涉及的全部 labelId（并集），渲染时过滤出用户标签。
    var labelIds: [String] = []
    /// 来源账号（聚合视图里区分不同账号）。
    var accountID: String = ""

    /// 选择用的 key。
    var key: SelectedThread { SelectedThread(accountID: accountID, threadID: id) }

    /// 单封邮件即一行（不按会话显示时）。
    init(message: PooledMessage, account: String) {
        id = message.id
        from = message.from
        subject = message.subject
        snippet = message.snippet
        date = message.date
        isUnread = message.isUnread
        isStarred = message.isStarred
        hasAttachment = message.hasAttachment
        messageCount = 1
        labelIds = message.labelIds
        accountID = account
    }

    /// 一整串会话即一行。信头取最新一封，状态和标签取整串的并集。
    ///
    /// 计数只数池子里有的：回溯范围之外的早期邮件不在本地，也就不参与聚合。
    init?(thread: String, messages: [PooledMessage], account: String) {
        guard let last = messages.last else { return nil }
        id = thread
        from = last.from
        subject = last.subject
        snippet = last.snippet
        date = last.date
        isUnread = messages.contains(where: \.isUnread)
        isStarred = messages.contains(where: \.isStarred)
        hasAttachment = messages.contains(where: \.hasAttachment)
        messageCount = messages.count
        // 排个序：Set 倒出来的顺序每次都可能不同，而行是按值比较的——
        // 标签一个没变、只是换了个顺序，也会被当成这一行变了。
        labelIds = Set(messages.flatMap(\.labelIds)).sorted()
        accountID = account
    }
}

/// 列表的已读/未读过滤（仿 Apple Mail 右上角的过滤器）。纯本地判断，不再走查询。
enum ReadFilter: String, CaseIterable, Identifiable {
    case all, unread, read

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部邮件"
        case .unread: return "仅未读"
        case .read: return "仅已读"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .unread: return "envelope.badge"
        case .read: return "envelope.open"
        }
    }

    func matches(_ summary: ThreadSummary) -> Bool {
        switch self {
        case .all: return true
        case .unread: return summary.isUnread
        case .read: return !summary.isUnread
        }
    }
}

/// 中栏列表的视图模型。
///
/// 不再自己拉数据、不再自己存数据——邮件都在 `MailStore` 的账户池里，
/// 这里只负责「按当前选中的邮箱和显示方式，把池子里的邮件算成一行行」，
/// 以及把用户在行上的操作翻译成对池子的改动加一个 API 请求。
///
/// 所以切换邮箱是纯本地计算，一个网络请求都不会发。
@MainActor
final class ThreadListModel: ObservableObject {
    @Published private(set) var summaries: [ThreadSummary] = [] {
        didSet { summariesVersion &+= 1 }
    }
    @Published var loadError: String?

    /// `summaries` 每换一次加一。视图那边拿它当缓存的钥匙（见 `ThreadRowCoordinator.rowItems`）：
    /// 比对一个整数，而不是把上万行逐行比一遍。
    private(set) var summariesVersion = 0

    private var store: MailStore?
    private var cancellable: AnyCancellable?
    private var recomputeTask: Task<Void, Never>?
    private var lastRecompute: ContinuousClock.Instant = .now - .seconds(3600)

    private(set) var accounts: [String] = []
    private(set) var labelID = ""
    private var boxQuery = MailboxQuery.resolve(labelID: "INBOX")
    /// 是否按会话显示；false 时每行是一封独立邮件，行 id 为 messageId。
    private(set) var conversation = true
    private(set) var filter: ReadFilter = .all
    /// 当前的本地搜索词（空即没在搜）。
    private(set) var search = MailSearchQuery.empty
    /// 搜索范围：只搜当前邮箱，还是搜遍所有邮件。
    private(set) var searchScope: SearchScope = .mailbox
    /// 放宽到账号或所有账号时用的归属判断（仍然把垃圾邮件和废纸篓摘出去）。
    private let allMailQuery = MailboxQuery.resolve(labelID: StandardMailbox.allMailID)

    /// 正在搜索。
    var isSearching: Bool { !search.isEmpty }

    /// 当前该用哪套归属判断：搜索范围一旦超出「当前邮箱」，就不再受选中的邮箱限制。
    /// 参与计算的是哪几个账号由调用方定（见 `ThreadListView.searchAccounts`）。
    private var activeQuery: MailboxQuery {
        isSearching && !searchScope.isMailbox ? allMailQuery : boxQuery
    }

    /// 池子里的邮件一变就跟着变。
    func bind(to store: MailStore) {
        guard self.store !== store else { return }
        self.store = store
        // 订阅当场回放的那一下不要：它不代表任何变化，紧跟着的 `configure` 会算第一遍
        cancellable = store.$revision.dropFirst().sink { [weak self, weak store] _ in
            guard let self, let store else { return }
            self.poolChanged(store.lastChange)
        }
    }

    /// 一次只改几封的标签时就地改那几行，超过这个数就整份重算。
    ///
    /// 就地改每一行都要在列表里找一遍它，行数乘上去之后不比重算便宜。
    private static let patchLimit = 32

    private func poolChanged(_ change: MailStore.PoolChange) {
        guard case .labels(let account, let ids) = change else {
            scheduleRecompute()
            return
        }
        // 别的账号的标签变动，和这张列表没有关系
        guard accounts.contains(account) else { return }
        // 已经有一次整份重算在等着了，就都交给它：这会儿的 `summaries` 本来就落后于池子
        if recomputeTask == nil, ids.count <= Self.patchLimit {
            patch(account: account, ids: ids)
        } else {
            scheduleRecompute()
        }
    }

    /// 变化密集时合并重算。
    ///
    /// 重算要把整个账户池分组、排序，几千封就是几千封；而池子的版本号变得很密——
    /// 回溯每拉回一页加一次、连着标十几封已读就加十几次。不合并的话，
    /// 一次首轮同步能让同一份列表重算几十遍，全压在主线程上。
    ///
    /// 但也不能一律延后：点一下「标为已读」，那个小圆点该当场就灭。
    /// 所以隔了一会儿的第一次变化立刻算，紧跟着的才攒起来——
    /// 单个操作照旧即时，成串的变化只算一次。
    private static let mergeWindow: Duration = .milliseconds(80)

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = nil
        if ContinuousClock.now - lastRecompute >= Self.mergeWindow {
            recompute()
            return
        }
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mergeWindow)
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    /// 切换邮箱 / 显示方式 / 过滤器 / 搜索词。纯本地，不联网。
    func configure(accounts: [String], labelID: String, conversation: Bool, filter: ReadFilter,
                   search: String = "", searchScope: SearchScope = .mailbox) {
        self.accounts = accounts
        self.labelID = labelID
        self.conversation = conversation
        self.filter = filter
        self.search = MailSearchQuery.parse(search)
        self.searchScope = searchScope
        boxQuery = MailboxQuery.resolve(labelID: labelID)
        loadError = nil
        recompute()
    }

    // MARK: - 派生

    private func recompute() {
        recomputeTask?.cancel()
        recomputeTask = nil
        lastRecompute = .now
        guard let store else { summaries = []; return }
        var rows: [ThreadSummary] = []
        for account in accounts {
            let all = store.messages(account: account)
            if conversation {
                for (thread, group) in Dictionary(grouping: all, by: \.threadId) {
                    if let row = row(thread: thread, messages: group, account: account) {
                        rows.append(row)
                    }
                }
            } else {
                rows += all.compactMap { row(message: $0, account: account) }
            }
        }
        summaries = rows.sorted(by: Self.precedes)
    }

    /// 只有几封邮件的标签变了：把它们所在的那几行改掉，其余的不动。
    ///
    /// 结果必须和整份重算一模一样，所以一行该不该在、长什么样，和 `recompute` 问的是
    /// 同一对函数（`row(message:)` / `row(thread:)`）。标签变动不改邮件的时间，
    /// 原来就在列表里的行位置不变；新进来的按时间插到该在的地方。
    private func patch(account: String, ids: [String]) {
        guard let store else { return }
        // 这几封邮件各自落在哪一行（会话模式下几封可能是同一串）
        var rowIDs: [String] = []
        for id in ids {
            let rowID = conversation ? (store.message(account: account, id: id)?.threadId ?? id) : id
            if !rowIDs.contains(rowID) { rowIDs.append(rowID) }
        }

        var rows = summaries
        var changed = false
        for rowID in rowIDs {
            let fresh: ThreadSummary?
            if conversation {
                fresh = row(thread: rowID,
                            messages: store.threadMessages(account: account, threadID: rowID),
                            account: account)
            } else {
                fresh = store.message(account: account, id: rowID).flatMap { row(message: $0, account: account) }
            }
            let index = rows.firstIndex { $0.id == rowID && $0.accountID == account }
            switch (index, fresh) {
            case (nil, nil):
                continue
            case (let index?, nil):
                rows.remove(at: index)
            case (let index?, let fresh?):
                guard rows[index] != fresh else { continue }
                rows[index] = fresh
            case (nil, let fresh?):
                rows.insert(fresh, at: Self.insertionIndex(for: fresh, in: rows))
            }
            changed = true
        }
        if changed { summaries = rows }
    }

    /// 这封邮件在当前列表里是哪一行；不该出现（不在这个邮箱、没命中搜索、被过滤掉）则为 nil。
    private func row(message: PooledMessage, account: String) -> ThreadSummary? {
        guard activeQuery.belongs(message), search.isEmpty || search.matches(message) else { return nil }
        let row = ThreadSummary(message: message, account: account)
        return filter.matches(row) ? row : nil
    }

    /// 这串会话在当前列表里是哪一行；不该出现则为 nil。`messages` 是整串，顺序不限。
    ///
    /// 先看整串再判断归属：一串会话只要有一封在这个邮箱，整串就显示，
    /// 而计数、标签、状态取的是整串——和 Gmail、Apple Mail 的会话语义一致。
    /// （反过来先过滤再分组的话，收件箱里那串「3 封」会缩水成「在收件箱的那 1 封」。）
    private func row(thread: String, messages: [PooledMessage], account: String) -> ThreadSummary? {
        let box = activeQuery
        guard messages.contains(where: { box.belongs($0) }) else { return nil }
        // 搜索同理按整串算：串里有一封命中，整串就是结果。行上显示的
        // 本来就是整串，只把命中的那一封抠出来反而对不上下文。
        guard search.isEmpty || messages.contains(where: { search.matches($0) }) else { return nil }
        // 时间相同的按 id 定先后，否则「最新一封」是谁会随传进来的顺序变
        let sorted = messages.sorted {
            let (x, y) = ($0.date ?? .distantPast, $1.date ?? .distantPast)
            return x != y ? x < y : $0.id < $1.id
        }
        guard let row = ThreadSummary(thread: thread, messages: sorted, account: account),
              filter.matches(row) else { return nil }
        return row
    }

    /// 列表的顺序：新的在前。时间相同的按 id 定先后——没有这一条，同一秒到的几封信
    /// 谁先谁后全看字典当时怎么排，每重算一次都可能换个位置。
    private static func precedes(_ a: ThreadSummary, _ b: ThreadSummary) -> Bool {
        let (x, y) = (a.date ?? .distantPast, b.date ?? .distantPast)
        if x != y { return x > y }
        if a.id != b.id { return a.id > b.id }
        return a.accountID > b.accountID
    }

    /// 新的一行该插在已经排好的列表的哪儿（二分）。
    private static func insertionIndex(for row: ThreadSummary, in rows: [ThreadSummary]) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if precedes(rows[mid], row) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 一行对应池子里的哪些邮件：会话模式下是整串，否则就它自己。
    func messageIDs(for key: SelectedThread) -> [String] {
        guard let store else { return [] }
        if conversation {
            return store.threadMessages(account: key.accountID, threadID: key.threadID).map(\.id)
        }
        return store.message(account: key.accountID, id: key.threadID) == nil ? [] : [key.threadID]
    }

    /// 这一行现在在收件箱、归档，还是废纸篓。
    func placement(of key: SelectedThread) -> MailPlacement {
        guard let store else { return .archived }
        return MailPlacement(labels: store.labels(account: key.accountID, threadID: key.threadID,
                                                  conversation: conversation))
    }

    /// 这一行按这组标签改完之后，还留在当前邮箱里吗。
    ///
    /// 用来决定归档/移回收件箱要不要顺手选中下一封：在「所有邮件」里这两个操作并不会
    /// 把行拿走，那时候还去动选择，用户只会觉得莫名其妙跳走了一封。
    func remainsVisible(_ key: SelectedThread, add: [String] = [], remove: [String] = []) -> Bool {
        guard let store else { return false }
        var labels = store.labels(account: key.accountID, threadID: key.threadID,
                                  conversation: conversation)
        labels.formUnion(add)
        labels.subtract(remove)
        return activeQuery.labelsBelong(Array(labels))
    }

    // MARK: - 操作（本地先改，再发请求；失败才回头问服务器）

    /// 批量增删标签（归档 = 去 INBOX；已读 = 去 UNREAD；旗标 = 加 STARRED）。
    func mutateMany(_ keys: [SelectedThread], add: [String] = [], remove: [String] = []) async {
        guard let store, !keys.isEmpty, !add.isEmpty || !remove.isEmpty else { return }
        let affected = applyLocally(keys, add: add, remove: remove)
        if let error = await MailActions.modify(keys, add: add, remove: remove, conversation: conversation) {
            loadError = error
            for (account, ids) in affected {
                await store.revalidate(account: account, messageIDs: ids)
            }
        }
    }

    /// 只改本地（详情栏已经发过请求了，列表这边照着算一遍就行）。
    @discardableResult
    func applyLocally(_ keys: [SelectedThread], add: [String], remove: [String]) -> [String: [String]] {
        guard let store else { return [:] }
        var affected: [String: [String]] = [:]
        for key in keys {
            let ids = messageIDs(for: key)
            guard !ids.isEmpty else { continue }
            store.applyLabels(account: key.accountID, messageIDs: ids, add: add, remove: remove)
            affected[key.accountID, default: []] += ids
        }
        return affected
    }

    /// 删除（移入废纸篓）。
    func trashMany(_ keys: [SelectedThread]) async {
        guard let store, !keys.isEmpty else { return }
        var affected: [String: [String]] = [:]
        for key in keys {
            let ids = messageIDs(for: key)
            guard !ids.isEmpty else { continue }
            store.applyTrash(account: key.accountID, messageIDs: ids)
            affected[key.accountID, default: []] += ids
        }

        let byConversation = conversation
        let failures = await withTaskGroup(of: String?.self) { group -> [String] in
            for key in keys {
                group.addTask {
                    let api = GmailAPI(account: key.accountID)
                    do {
                        if byConversation {
                            try await api.trashThread(id: key.threadID)
                        } else {
                            try await api.trashMessage(id: key.threadID)
                        }
                        return nil
                    } catch {
                        return key.accountID
                    }
                }
            }
            var out: [String] = []
            for await failed in group { if let failed { out.append(failed) } }
            return out
        }

        guard !failures.isEmpty else { return }
        loadError = "部分邮件删除失败"
        for account in Set(failures) {
            await store.revalidate(account: account, messageIDs: affected[account] ?? [])
        }
    }

    /// 放回收件箱（归档的、以及废纸篓里的）。
    ///
    /// 废纸篓那部分得先 `untrash` 再 `modify`，理由见 `MessageDetailModel.moveToInbox`。
    func moveToInboxMany(_ keys: [SelectedThread]) async {
        guard let store, !keys.isEmpty else { return }
        var affected: [String: [String]] = [:]
        var trashed: Set<SelectedThread> = []
        for key in keys {
            let ids = messageIDs(for: key)
            guard !ids.isEmpty else { continue }
            if placement(of: key) == .trashed { trashed.insert(key) } // 本地一改就看不出来了
            store.applyMoveToInbox(account: key.accountID, messageIDs: ids)
            affected[key.accountID, default: []] += ids
        }

        let byConversation = conversation
        let failures = await withTaskGroup(of: String?.self) { group -> [String] in
            for key in keys {
                let wasTrashed = trashed.contains(key)
                group.addTask {
                    let api = GmailAPI(account: key.accountID)
                    do {
                        if byConversation {
                            if wasTrashed { try await api.untrashThread(id: key.threadID) }
                            try await api.modifyThread(id: key.threadID, add: MailPlacement.inboxAdd,
                                                       remove: MailPlacement.inboxRemove)
                        } else {
                            if wasTrashed { try await api.untrashMessage(id: key.threadID) }
                            try await api.modifyMessage(id: key.threadID, add: MailPlacement.inboxAdd,
                                                        remove: MailPlacement.inboxRemove)
                        }
                        return nil
                    } catch {
                        return key.accountID
                    }
                }
            }
            var out: [String] = []
            for await failed in group { if let failed { out.append(failed) } }
            return out
        }

        guard !failures.isEmpty else { return }
        loadError = "部分邮件没能移回收件箱"
        for account in Set(failures) {
            await store.revalidate(account: account, messageIDs: affected[account] ?? [])
        }
    }
}
