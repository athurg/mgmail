import SwiftUI

/// 渲染用的单封邮件视图模型。
struct RenderedMessage: Codable, Identifiable {
    let id: String
    let fromName: String
    let fromEmail: String
    let to: String
    let date: Date?
    let subject: String
    let bodyHTML: String
    let attachments: [Attachment]
    /// 折叠态用的预览摘要（Gmail 提供的 snippet）。可选以兼容旧缓存解码。
    let snippet: String?
    /// 本封的 Message-ID 头。回复时填进 In-Reply-To，对方的客户端才能把回信
    /// 串进原会话。可选以兼容旧缓存解码。
    let messageIDHeader: String?
    /// 原会话已有的 Message-ID 链（References 头）。回复时接在后面。
    let referencesHeader: [String]?

    @MainActor
    var dateText: String { DateText.messageHeader(date) }

    /// 返回替换了正文的副本。
    func withBody(_ html: String) -> RenderedMessage {
        RenderedMessage(id: id, fromName: fromName, fromEmail: fromEmail, to: to, date: date,
                        subject: subject, bodyHTML: html, attachments: attachments, snippet: snippet,
                        messageIDHeader: messageIDHeader, referencesHeader: referencesHeader)
    }
}

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
    var isInInbox: Bool { threadLabelIds.contains("INBOX") }
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

    /// 从服务器取正文，解析内联图片后写进缓存。一次请求拿完。
    private func fetch(account: String, threadID: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let api = GmailAPI(account: account)
            let raw: [GmailMessage]
            if conversation {
                raw = try await api.getThread(id: threadID, format: "full").messages ?? []
            } else {
                raw = [try await api.getMessage(id: threadID, format: "full")]
            }
            guard self.threadID == threadID else { return } // 期间已切换

            // 先把内联图片全部解析好再一次性设置，避免出现「原始 cid → 解析后」的中间态闪烁
            var rendered = raw.map { Self.render($0) }
            let complete: Bool
            (rendered, complete) = await resolveInline(rendered, rawMessages: raw, account: account)
            guard self.threadID == threadID else { return }

            messages = rendered
            subject = rendered.first?.subject ?? "（无主题）"
            // 有内联图没换下来就先不落盘。正文缓存是「一辈子只拉一次」的，
            // 这时候存进去，一次网络抖动造成的破图就再也没机会修好了。
            guard complete else { return }
            let cached = CachedThread(subject: subject, messages: rendered)
            await MailCache.shared.saveThread(cached, account: account, threadID: threadID,
                                              conversation: conversation)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 会话里多了新邮件时重取（同步发现变化才会调用）。
    func reloadBody() async {
        guard let account, let threadID else { return }
        await fetch(account: account, threadID: threadID)
    }

    /// 把正文里的 `cid:` 内联图片替换为 data URI；优先用缓存，缺失才下载并缓存。
    ///
    /// 第二个返回值是「有没有全换下来」。有一张没换成，这份正文就不该进缓存——
    /// 详见 `fetch` 里落盘前的那道判断。
    private func resolveInline(_ rendered: [RenderedMessage], rawMessages: [GmailMessage],
                               account: String) async -> (messages: [RenderedMessage], complete: Bool) {
        var result = rendered
        var complete = true
        for message in rawMessages {
            let inlines = MimeParser.inlineImages(message.payload)
            guard !inlines.isEmpty,
                  let idx = result.firstIndex(where: { $0.id == message.id }),
                  result[idx].bodyHTML.contains("cid:") else { continue }

            var html = result[idx].bodyHTML
            for img in inlines where html.contains("cid:\(img.contentID)") {
                // 用 Content-ID 而不是 attachmentId 做键：后者是 Gmail 每次 get 现发的临时票据，
                // 同一张图每次拉回来都不一样，拿它当键等于缓存永远不命中，每次都重下一遍。
                let key = "\(message.id)_\(img.contentID)"
                let uri: String
                if let cached = await MailCache.shared.inlineDataURI(account: account, key: key) {
                    uri = cached
                } else if let data = try? await GmailAPI(account: account)
                    .getAttachment(messageID: message.id, attachmentId: img.attachmentId) {
                    uri = "data:\(img.mimeType);base64,\(data.base64EncodedString())"
                    await MailCache.shared.saveInlineDataURI(uri, account: account, key: key)
                } else {
                    complete = false
                    continue
                }
                html = html.replacingOccurrences(of: "cid:\(img.contentID)", with: uri)
            }
            result[idx] = result[idx].withBody(html)
        }
        return (result, complete)
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

    /// 打开会话时若未读则自动标记为已读。
    func markReadOnOpenIfNeeded() async {
        guard isUnread else { return }
        try? await setUnread(false)
    }

    nonisolated static func render(_ message: GmailMessage) -> RenderedMessage {
        let fromHeader = MimeParser.header(message.payload, "From") ?? ""
        let from = EmailAddress(header: fromHeader)
        let to = MimeParser.header(message.payload, "To") ?? ""
        let subject = MimeParser.header(message.payload, "Subject") ?? "（无主题）"

        let (html, text) = MimeParser.extractBody(message.payload)
        let body: String
        if let html, !html.isEmpty {
            body = html
        } else if let text, !text.isEmpty {
            body = "<div style=\"white-space:pre-wrap\">\(escapeHTML(text))</div>"
        } else {
            body = "<p style=\"color:#888\">（此邮件没有可显示的正文）</p>"
        }

        return RenderedMessage(
            id: message.id,
            fromName: from.name,
            fromEmail: from.email,
            to: to,
            date: message.date,
            subject: subject,
            bodyHTML: body,
            attachments: MimeParser.attachments(message.payload, messageID: message.id),
            snippet: message.snippet,
            messageIDHeader: MimeParser.header(message.payload, "Message-ID"),
            referencesHeader: MimeParser.header(message.payload, "References")?
                .split(whereSeparator: \.isWhitespace).map(String.init)
        )
    }

    nonisolated static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
