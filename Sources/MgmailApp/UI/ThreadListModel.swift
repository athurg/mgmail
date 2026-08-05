import SwiftUI

/// 会话列表中的一行摘要。
struct ThreadSummary: Codable, Identifiable, Hashable {
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
}

/// 列表的已读/未读过滤（仿 Apple Mail 右上角的过滤器）。
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

    /// 传给 Gmail API 的查询串。
    var query: String? {
        switch self {
        case .all: return nil
        case .unread: return "is:unread"
        case .read: return "is:read"
        }
    }

    /// 某条摘要在当前过滤下是否仍应留在列表里。
    func matches(_ summary: ThreadSummary) -> Bool {
        switch self {
        case .all: return true
        case .unread: return summary.isUnread
        case .read: return !summary.isUnread
        }
    }
}

/// 把选中的邮箱标识解析成 Gmail API 查询参数与「是否仍属于该邮箱」的判定。
struct MailboxQuery {
    let apiLabelID: String?
    let includeSpamTrash: Bool
    /// 单封邮件是否仍属于该邮箱。
    let messageBelongs: (GmailMessage) -> Bool

    /// 会话只要有一封邮件仍属于该邮箱就保留。
    func stillBelongs(_ thread: GmailThread) -> Bool {
        (thread.messages ?? []).contains(where: messageBelongs)
    }

    static func resolve(labelID: String) -> MailboxQuery {
        if let box = StandardMailbox.all.first(where: { $0.id == labelID }) {
            if box.id == StandardMailbox.allMailID {
                // 所有邮件：不按标签过滤，且排除垃圾/废纸篓
                return MailboxQuery(apiLabelID: nil, includeSpamTrash: false) { m in
                    let l = m.labelIds ?? []
                    return !l.contains("TRASH") && !l.contains("SPAM")
                }
            }
            let apiID = box.apiLabelID
            return MailboxQuery(apiLabelID: apiID, includeSpamTrash: box.includeSpamTrash) { m in
                guard let apiID else { return true }
                return (m.labelIds ?? []).contains(apiID)
            }
        }
        // 用户自定义标签
        return MailboxQuery(apiLabelID: labelID, includeSpamTrash: false) { m in
            (m.labelIds ?? []).contains(labelID)
        }
    }
}

/// 负责加载一个或多个账户的某个邮箱的会话列表（支持跨账号聚合）。
@MainActor
final class ThreadListModel: ObservableObject {
    @Published var summaries: [ThreadSummary] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private struct AccountCursor {
        var pageToken: String?
        var exhausted: Bool
    }

    private var accountsToLoad: [String] = []
    private var labelID: String = ""
    private var boxQuery: MailboxQuery = .resolve(labelID: "INBOX")
    private var cacheKey: String = ""
    private var cursors: [String: AccountCursor] = [:]
    private var generation = 0
    /// 是否按会话显示；false 时每行是一封独立邮件，行 id 为 messageId。
    private(set) var conversation = true
    /// 当前的已读/未读过滤。
    private(set) var filter: ReadFilter = .all

    /// 列表缓存的文件名 key：两种模式的行 id 语义不同，必须分开存。
    private var cacheLabelKey: String {
        conversation ? labelID : labelID + "__messages"
    }

    /// 过滤态下的列表是「全部」的子集，写回缓存会污染全量缓存，故只在无过滤时读写。
    private var usesCache: Bool { filter == .all }

    /// 还有账号可以继续翻页。
    var hasMore: Bool {
        accountsToLoad.contains { !(cursors[$0]?.exhausted ?? true) }
    }

    /// 加载指定邮箱（accounts 多个即聚合）：先用缓存 seed，再后台拉最新（SWR）。
    func load(accounts: [String], labelID: String, conversation: Bool, filter: ReadFilter) async {
        generation += 1
        let gen = generation
        accountsToLoad = accounts
        self.labelID = labelID
        self.conversation = conversation
        self.filter = filter
        boxQuery = MailboxQuery.resolve(labelID: labelID)
        cacheKey = accounts.count == 1 ? accounts[0] : "__all__"
        cursors = [:]
        loadError = nil

        // 过滤态没有对应缓存，但可以先用全量缓存里符合条件的部分顶上，避免整屏空白
        if let cached = await MailCache.shared.summaries(account: cacheKey, labelID: cacheLabelKey) {
            guard gen == generation else { return }
            summaries = cached.filter { filter.matches($0) }
        } else {
            summaries = []
        }
        await fetchPage(reset: true, gen: gen)
    }

    /// 翻下一页（每个还有余量的账号各拉一页，再按时间归并）。
    func loadMore() async {
        guard !isLoading, hasMore else { return }
        await fetchPage(reset: false, gen: generation)
    }

    private func fetchPage(reset: Bool, gen: Int) async {
        guard !accountsToLoad.isEmpty else { return }
        isLoading = true
        defer { if gen == generation { isLoading = false } }

        // 本轮要拉的账号及其 pageToken
        let toFetch: [(account: String, token: String?)]
        if reset {
            toFetch = accountsToLoad.map { ($0, nil) }
        } else {
            toFetch = accountsToLoad.compactMap { acc in
                guard let c = cursors[acc], !c.exhausted else { return nil }
                return (acc, c.pageToken)
            }
        }
        guard !toFetch.isEmpty else { return }

        let apiLabelID = boxQuery.apiLabelID
        let includeSpamTrash = boxQuery.includeSpamTrash
        let byConversation = conversation
        let filterQuery = filter.query
        let results = await withTaskGroup(of: FetchResult.self) { group -> [FetchResult] in
            for (acc, token) in toFetch {
                group.addTask {
                    let api = GmailAPI(account: acc)
                    do {
                        if byConversation {
                            let list = try await api.listThreads(labelId: apiLabelID, query: filterQuery,
                                                                 pageToken: token, includeSpamTrash: includeSpamTrash)
                            let details = try await Self.fetchSummaries(refs: list.threads ?? [], api: api, account: acc)
                            return FetchResult(account: acc, summaries: details, nextToken: list.nextPageToken, failed: false)
                        } else {
                            let list = try await api.listMessages(labelId: apiLabelID, query: filterQuery,
                                                                  pageToken: token, includeSpamTrash: includeSpamTrash)
                            let details = try await Self.fetchMessageSummaries(refs: list.messages ?? [], api: api, account: acc)
                            return FetchResult(account: acc, summaries: details, nextToken: list.nextPageToken, failed: false)
                        }
                    } catch {
                        return FetchResult(account: acc, summaries: [], nextToken: nil, failed: true)
                    }
                }
            }
            var out: [FetchResult] = []
            for await r in group { out.append(r) }
            return out
        }

        guard gen == generation else { return } // 期间已切换邮箱/账号

        var merged: [ThreadSummary] = reset ? [] : summaries
        var failures = 0
        for r in results {
            if r.failed { failures += 1; continue }
            cursors[r.account] = AccountCursor(pageToken: r.nextToken, exhausted: r.nextToken == nil)
            merged.append(contentsOf: r.summaries)
        }
        // 会话模式下 is:read 可能命中「含未读邮件」的会话，再按行状态兜一遍，保证列表自洽
        merged = Self.dedupeAndSort(merged).filter { filter.matches($0) }

        if reset {
            // 至少一个账号成功才覆盖；全失败则保留缓存内容
            if failures < results.count {
                summaries = merged
                await persistCache()
            } else if summaries.isEmpty {
                loadError = "加载失败，请重试"
            }
        } else {
            summaries = merged
            await persistCache()
        }
    }

    /// 写回列表缓存（过滤态不写，避免污染全量缓存）。
    private func persistCache() async {
        guard usesCache else { return }
        await MailCache.shared.saveSummaries(summaries, account: cacheKey, labelID: cacheLabelKey)
    }

    /// 某会话/邮件被修改后，重新拉取该行；若已不属于当前邮箱则移除。
    func refreshRow(account: String, id: String) async {
        guard summaries.contains(where: { $0.id == id && $0.accountID == account }) else { return }
        let headers = ["From", "To", "Subject", "Date"]
        let api = GmailAPI(account: account)

        let fresh: (summary: ThreadSummary, belongs: Bool)?
        if conversation {
            guard let thread = try? await api.getThread(id: id, format: "metadata", metadataHeaders: headers),
                  let old = summaries.first(where: { $0.id == id && $0.accountID == account }) else { return }
            fresh = (Self.summarize(thread: thread, fallbackSnippet: old.snippet, account: account),
                     boxQuery.stillBelongs(thread))
        } else {
            guard let message = try? await api.getMessage(id: id, format: "metadata", metadataHeaders: headers) else { return }
            fresh = (Self.summarize(message: message, account: account), boxQuery.messageBelongs(message))
        }
        guard let fresh, let idx = summaries.firstIndex(where: { $0.id == id && $0.accountID == account }) else { return }

        // 不再属于该邮箱、或不再符合当前过滤（如「仅未读」里被标记已读）就移除
        if fresh.belongs && filter.matches(fresh.summary) {
            summaries[idx] = fresh.summary
        } else {
            summaries.remove(at: idx)
        }
        await persistCache()
    }

    /// 删除（移入废纸篓）：立即从列表移除，再调用 API。
    func trash(account: String, id: String) async {
        removeRow(account: account, id: id)
        do {
            try await self.trashRemote(account: account, id: id)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await refreshRow(account: account, id: id) // 失败则以服务器状态为准
        }
    }

    private func removeRow(account: String, id: String) {
        if let idx = summaries.firstIndex(where: { $0.id == id && $0.accountID == account }) {
            summaries.remove(at: idx)
            Task { await persistCache() }
        }
    }

    /// 批量删除（移入废纸篓）。
    func trashMany(_ keys: [SelectedThread]) async {
        for k in keys {
            if let idx = summaries.firstIndex(where: { $0.id == k.threadID && $0.accountID == k.accountID }) {
                summaries.remove(at: idx)
            }
        }
        await persistCache()
        let byConversation = conversation
        await withTaskGroup(of: Void.self) { group in
            for k in keys {
                group.addTask {
                    let api = GmailAPI(account: k.accountID)
                    if byConversation {
                        try? await api.trashThread(id: k.threadID)
                    } else {
                        try? await api.trashMessage(id: k.threadID)
                    }
                }
            }
        }
    }

    /// 批量增删标签（归档 = 去 INBOX；已读 = 去 UNREAD；旗标 = 加 STARRED）。
    func mutateMany(_ keys: [SelectedThread], add: [String] = [], remove: [String] = []) async {
        if let error = await MailActions.modify(keys, add: add, remove: remove, conversation: conversation) {
            loadError = error
        }
        for k in keys { await refreshRow(account: k.accountID, id: k.threadID) }
    }

    /// 行内快捷操作：加/去标签或读未读，成功后刷新该行。
    func mutate(account: String, id: String, add: [String] = [], remove: [String] = []) async {
        do {
            let api = GmailAPI(account: account)
            if conversation {
                try await api.modifyThread(id: id, add: add, remove: remove)
            } else {
                try await api.modifyMessage(id: id, add: add, remove: remove)
            }
            await refreshRow(account: account, id: id)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func trashRemote(account: String, id: String) async throws {
        let api = GmailAPI(account: account)
        if conversation {
            try await api.trashThread(id: id)
        } else {
            try await api.trashMessage(id: id)
        }
    }

    // MARK: - 静态辅助

    private struct FetchResult {
        let account: String
        let summaries: [ThreadSummary]
        let nextToken: String?
        let failed: Bool
    }

    /// 按 (账号+id) 去重，并按时间倒序排序。
    nonisolated static func dedupeAndSort(_ items: [ThreadSummary]) -> [ThreadSummary] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert("\($0.accountID)\t\($0.id)").inserted }
        return unique.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// 按顺序、限并发地拉取会话元数据并转成摘要。
    nonisolated static func fetchSummaries(refs: [ThreadRef], api: GmailAPI, account: String) async throws -> [ThreadSummary] {
        let headers = ["From", "To", "Subject", "Date"]
        var result: [ThreadSummary] = []
        let batchSize = 6
        var index = 0
        while index < refs.count {
            let batch = Array(refs[index..<min(index + batchSize, refs.count)])
            let fetched: [ThreadSummary?] = try await withThrowingTaskGroup(of: (Int, ThreadSummary?).self) { group in
                for (offset, ref) in batch.enumerated() {
                    group.addTask {
                        let thread = try? await api.getThread(id: ref.id, format: "metadata", metadataHeaders: headers)
                        return (offset, thread.map { summarize(thread: $0, fallbackSnippet: ref.snippet ?? "", account: account) })
                    }
                }
                var slots = [ThreadSummary?](repeating: nil, count: batch.count)
                for try await (offset, summary) in group {
                    slots[offset] = summary
                }
                return slots
            }
            result.append(contentsOf: fetched.compactMap { $0 })
            index += batchSize
        }
        return result
    }

    /// 按顺序、限并发地拉取单封邮件元数据并转成摘要（不按会话显示时用）。
    nonisolated static func fetchMessageSummaries(refs: [MessageRef], api: GmailAPI, account: String) async throws -> [ThreadSummary] {
        let headers = ["From", "To", "Subject", "Date"]
        var result: [ThreadSummary] = []
        let batchSize = 6
        var index = 0
        while index < refs.count {
            let batch = Array(refs[index..<min(index + batchSize, refs.count)])
            let fetched: [ThreadSummary?] = try await withThrowingTaskGroup(of: (Int, ThreadSummary?).self) { group in
                for (offset, ref) in batch.enumerated() {
                    group.addTask {
                        let message = try? await api.getMessage(id: ref.id, format: "metadata", metadataHeaders: headers)
                        return (offset, message.map { summarize(message: $0, account: account) })
                    }
                }
                var slots = [ThreadSummary?](repeating: nil, count: batch.count)
                for try await (offset, summary) in group {
                    slots[offset] = summary
                }
                return slots
            }
            result.append(contentsOf: fetched.compactMap { $0 })
            index += batchSize
        }
        return result
    }

    /// 从单封邮件构造摘要（不按会话显示时，一行即一封）。
    nonisolated static func summarize(message: GmailMessage, account: String) -> ThreadSummary {
        let from = MimeParser.header(message.payload, "From").map { EmailAddress(header: $0).display } ?? "（未知发件人）"
        return ThreadSummary(
            id: message.id,
            from: from,
            subject: MimeParser.header(message.payload, "Subject") ?? "（无主题）",
            snippet: message.snippet ?? "",
            date: message.date,
            isUnread: message.isUnread,
            isStarred: message.isStarred,
            hasAttachment: !MimeParser.attachments(message.payload, messageID: message.id).isEmpty,
            messageCount: 1,
            labelIds: message.labelIds ?? [],
            accountID: account
        )
    }

    /// 从会话构造摘要（取最新一封邮件的头信息）。
    nonisolated static func summarize(thread: GmailThread, fallbackSnippet: String, account: String) -> ThreadSummary {
        let messages = thread.messages ?? []
        let last = messages.last
        let from = MimeParser.header(last?.payload, "From").map { EmailAddress(header: $0).display } ?? "（未知发件人）"
        let subject = MimeParser.header(last?.payload, "Subject") ?? "（无主题）"
        let isUnread = messages.contains { $0.isUnread }
        let isStarred = messages.contains { $0.isStarred }
        let hasAttachment = messages.contains { !MimeParser.attachments($0.payload, messageID: $0.id).isEmpty }
        let labelIds = Array(Set(messages.flatMap { $0.labelIds ?? [] }))
        return ThreadSummary(
            id: thread.id,
            from: from,
            subject: subject,
            snippet: fallbackSnippet,
            date: last?.date,
            isUnread: isUnread,
            isStarred: isStarred,
            hasAttachment: hasAttachment,
            messageCount: messages.count,
            labelIds: labelIds,
            accountID: account
        )
    }
}
