import SwiftUI

/// 加载并渲染某个会话（或单封邮件）的正文。
///
/// 正文是不可变的，所以规则很简单：**一封邮件（或一串会话）一辈子只拉一次**。
/// 缓存里有就直接用，没有就拉一次并写进缓存，此后再打开都不联网。
///
/// 邮件的属性（读没读、有没有星标、在哪个邮箱）不在这里——那些全是标签，
/// 由 `MailStore` 的账户池统一持有，详情栏只是读它，所以永远和列表一致。
@MainActor
final class MessageDetailModel: ObservableObject {
    @Published var subject: String = ""
    @Published var messages: [RenderedMessage] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private(set) var account: String?
    private(set) var threadID: String?
    /// 是否按会话显示；false 时 `threadID` 实为 messageId，只加载这一封。
    private(set) var conversation = true

    private var store: MailStore?

    func bind(to store: MailStore) {
        self.store = store
    }

    // MARK: - 属性（全部来自池子，这里不存副本）

    var threadLabelIds: Set<String> {
        guard let store, let account, let threadID else { return [] }
        return store.labels(account: account, threadID: threadID, conversation: conversation)
    }

    var isUnread: Bool { threadLabelIds.contains("UNREAD") }
    var isStarred: Bool { threadLabelIds.contains("STARRED") }
    /// 在收件箱、归档，还是废纸篓——工具栏上那两个按钮的面孔由它定。
    var placement: MailPlacement { MailPlacement(labels: threadLabelIds) }
    /// 是否带有用户自建标签（Gmail 的用户标签 id 统一以 "Label_" 开头）。
    var hasUserLabels: Bool { threadLabelIds.contains { $0.hasPrefix("Label_") } }

    /// 池子里这一行对应的邮件 id（会话模式下是整串）。
    var messageIDs: [String] {
        guard let store, let account, let threadID else { return [] }
        if conversation {
            return store.threadMessages(account: account, threadID: threadID).map(\.id)
        }
        return [threadID]
    }

    /// 某封邮件当前是否未读（卡片上的小圆点）。
    func isUnread(_ messageID: String) -> Bool {
        store?.message(account: account ?? "", id: messageID)?.isUnread ?? false
    }

    // MARK: - 正文

    /// 打开一封邮件/一串会话：缓存有就用缓存（不联网），没有才拉一次。
    func open(account: String, threadID: String, conversation: Bool) async {
        self.account = account
        self.threadID = threadID
        self.conversation = conversation
        loadError = nil

        if let cached = await MailCache.shared.thread(account: account, threadID: threadID,
                                                     conversation: conversation) {
            guard self.threadID == threadID else { return }
            messages = cached.messages
            subject = cached.subject
            return
        }
        messages = []
        subject = ""
        await fetch(account: account, threadID: threadID)
    }

    /// 从服务器取正文。取回、渲染、落缓存都在 `MessageBodyLoader` 里，
    /// 这里只负责把结果搬到界面上——同一条路后台预取也在走。
    private func fetch(account: String, threadID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await MessageBodyLoader.load(account: account, threadID: threadID,
                                                          conversation: conversation)
            guard self.threadID == threadID else { return } // 期间已切换
            messages = loaded.thread.messages
            subject = loaded.thread.subject
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 会话里多了新邮件时重取（同步发现变化才会调用）。
    func reloadBody() async {
        guard let account, let threadID else { return }
        await fetch(account: account, threadID: threadID)
    }

    // MARK: - 修改（读/星标/归档/标签）

    /// 应用一次标签增删：本地池子立刻更新，请求失败则抛给调用方。
    func modify(add: [String] = [], remove: [String] = []) async throws {
        guard let account, let threadID, let store else { return }
        let ids = messageIDs
        store.applyLabels(account: account, messageIDs: ids, add: add, remove: remove)
        do {
            let api = GmailAPI(account: account)
            if conversation {
                try await api.modifyThread(id: threadID, add: add, remove: remove)
            } else {
                try await api.modifyMessage(id: threadID, add: add, remove: remove)
            }
        } catch {
            await store.revalidate(account: account, messageIDs: ids)
            throw error
        }
    }

    func setUnread(_ unread: Bool) async throws {
        try await modify(add: unread ? ["UNREAD"] : [], remove: unread ? [] : ["UNREAD"])
    }

    func toggleStar() async throws {
        try await modify(add: isStarred ? [] : ["STARRED"], remove: isStarred ? ["STARRED"] : [])
    }

    func archive() async throws {
        try await modify(remove: ["INBOX"])
    }

    /// 放回收件箱：归档的直接加回 INBOX，废纸篓里的先捞出来再加。
    ///
    /// 从废纸篓回来要发两次请求：`untrash` 只负责把 TRASH 摘掉，落点是 Gmail 记着的
    /// 原位置（可能是「所有邮件」）；用户按的是「移回收件箱」，那就得再明确送进收件箱一次。
    func moveToInbox() async throws {
        guard let account, let threadID, let store else { return }
        let ids = messageIDs
        let wasTrashed = placement == .trashed // 本地一改就看不出来了，先记下
        store.applyMoveToInbox(account: account, messageIDs: ids)
        do {
            let api = GmailAPI(account: account)
            if conversation {
                if wasTrashed { try await api.untrashThread(id: threadID) }
                try await api.modifyThread(id: threadID, add: MailPlacement.inboxAdd,
                                           remove: MailPlacement.inboxRemove)
            } else {
                if wasTrashed { try await api.untrashMessage(id: threadID) }
                try await api.modifyMessage(id: threadID, add: MailPlacement.inboxAdd,
                                            remove: MailPlacement.inboxRemove)
            }
        } catch {
            await store.revalidate(account: account, messageIDs: ids)
            throw error
        }
    }

    /// 移入废纸篓。
    ///
    /// 独立阅读窗口用的是这条路，不像主窗口右栏那样把删除交给中栏列表——
    /// 那扇窗可能在主窗口关着的时候还开着，没人接的话删除就悄悄丢了。
    /// 代价是不会自动选中下一封，但删的时候用户眼睛在独立窗口上，列表选谁不打紧。
    func trash() async throws {
        guard let account, let threadID, let store else { return }
        let ids = messageIDs
        store.applyTrash(account: account, messageIDs: ids)
        do {
            let api = GmailAPI(account: account)
            if conversation {
                try await api.trashThread(id: threadID)
            } else {
                try await api.trashMessage(id: threadID)
            }
        } catch {
            await store.revalidate(account: account, messageIDs: ids)
            throw error
        }
    }

    /// 打开会话时若未读则自动标记为已读。
    func markReadOnOpenIfNeeded() async {
        guard isUnread else { return }
        try? await setUnread(false)
    }
}
