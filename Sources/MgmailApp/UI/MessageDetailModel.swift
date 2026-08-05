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
    let isUnread: Bool
    /// 折叠态用的预览摘要（Gmail 提供的 snippet）。可选以兼容旧缓存解码。
    let snippet: String?

    var dateText: String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: date)
    }

    /// 返回替换了正文的副本。
    func withBody(_ html: String) -> RenderedMessage {
        RenderedMessage(id: id, fromName: fromName, fromEmail: fromEmail, to: to, date: date,
                        subject: subject, bodyHTML: html, attachments: attachments, isUnread: isUnread,
                        snippet: snippet)
    }
}

/// 加载并渲染某个会话的全部邮件。
@MainActor
final class MessageDetailModel: ObservableObject {
    @Published var subject: String = ""
    @Published var messages: [RenderedMessage] = []
    @Published var isLoading = false
    @Published var loadError: String?

    /// 会话当前的标签集合（所有邮件 labelIds 的并集）。
    @Published var threadLabelIds: Set<String> = []

    private(set) var account: String?
    private(set) var threadID: String?
    /// 是否按会话显示；false 时 `threadID` 实为 messageId，只加载这一封。
    private(set) var conversation = true

    var isUnread: Bool { threadLabelIds.contains("UNREAD") }
    var isStarred: Bool { threadLabelIds.contains("STARRED") }
    var isInInbox: Bool { threadLabelIds.contains("INBOX") }

    /// 只用磁盘缓存 seed 显示，立即返回（不联网）。返回是否命中缓存。
    /// 拆出这一步是为了让调用方在缓存命中后能「立刻」展开正文，
    /// 而不必等后面的联网刷新完成（否则正文卡片会白等几秒才展开）。
    @discardableResult
    func seedFromCache(account: String, threadID: String, conversation: Bool) async -> Bool {
        self.account = account
        self.threadID = threadID
        self.conversation = conversation
        loadError = nil

        // 先从缓存 seed（瞬时显示，含已内联的图片）
        if let cached = await MailCache.shared.thread(account: account, threadID: threadID, conversation: conversation) {
            guard self.threadID == threadID else { return false }
            messages = cached.messages
            subject = cached.subject
            threadLabelIds = Set(cached.threadLabelIds)
            return true
        } else {
            messages = []
            return false
        }
    }

    /// 联网拉最新并写回缓存（SWR 的 R）。在 seedFromCache 之后调用。
    func refresh(account: String, threadID: String) async {
        isLoading = true
        defer { isLoading = false }
        await refreshFromServer(account: account, threadID: threadID)
    }

    /// 从服务器拉全量会话，重渲染（含内联图片解析）并写回缓存。尽力而为。
    /// 先把内联图片全部解析好，再一次性设置，避免出现「原始 cid → 解析后」的中间态闪烁；
    /// 内联图片按 消息+附件 id 缓存，不再每次打开都重下大图。
    private func refreshFromServer(account: String, threadID: String) async {
        do {
            let api = GmailAPI(account: account)
            let raw: [GmailMessage]
            if conversation {
                raw = try await api.getThread(id: threadID, format: "full").messages ?? []
            } else {
                raw = [try await api.getMessage(id: threadID, format: "full")]
            }
            guard self.threadID == threadID else { return } // 期间已切换

            var rendered = raw.map { Self.render($0) }
            rendered = await resolveInline(rendered, rawMessages: raw, account: account, threadID: threadID)
            guard self.threadID == threadID else { return }

            // 一次性设置最终结果（正文 HTML 与缓存一致时 WKWebView 不会重载，无闪烁）
            messages = rendered
            subject = rendered.first?.subject ?? "（无主题）"
            threadLabelIds = Set(raw.flatMap { $0.labelIds ?? [] })
            await saveCache(account: account, threadID: threadID)
        } catch {
            // 有缓存则保留展示；完全无内容时才报错
            if messages.isEmpty {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// 把当前渲染结果写入磁盘缓存。
    private func saveCache(account: String, threadID: String) async {
        let cached = CachedThread(subject: subject, messages: messages, threadLabelIds: Array(threadLabelIds))
        await MailCache.shared.saveThread(cached, account: account, threadID: threadID, conversation: conversation)
    }

    /// 把正文里的 `cid:` 内联图片替换为 data URI；优先用缓存，缺失才下载并缓存。
    private func resolveInline(_ rendered: [RenderedMessage], rawMessages: [GmailMessage],
                              account: String, threadID: String) async -> [RenderedMessage] {
        var result = rendered
        for message in rawMessages {
            let inlines = MimeParser.inlineImages(message.payload)
            guard !inlines.isEmpty,
                  let idx = result.firstIndex(where: { $0.id == message.id }),
                  result[idx].bodyHTML.contains("cid:") else { continue }

            var html = result[idx].bodyHTML
            for img in inlines where html.contains("cid:\(img.contentID)") {
                let key = "\(message.id)_\(img.attachmentId)"
                let uri: String
                if let cached = await MailCache.shared.inlineDataURI(account: account, key: key) {
                    uri = cached
                } else if let data = try? await GmailAPI(account: account)
                    .getAttachment(messageID: message.id, attachmentId: img.attachmentId) {
                    uri = "data:\(img.mimeType);base64,\(data.base64EncodedString())"
                    await MailCache.shared.saveInlineDataURI(uri, account: account, key: key)
                } else {
                    continue
                }
                html = html.replacingOccurrences(of: "cid:\(img.contentID)", with: uri)
            }
            result[idx] = result[idx].withBody(html)
        }
        return result
    }

    // MARK: - 修改（读/星标/归档/标签）

    /// 应用一次标签增删；modify 本身失败会抛错给调用方，之后尽力刷新并写缓存。
    func modify(add: [String] = [], remove: [String] = []) async throws {
        guard let account, let threadID else { return }
        let api = GmailAPI(account: account)
        if conversation {
            try await api.modifyThread(id: threadID, add: add, remove: remove)
        } else {
            try await api.modifyMessage(id: threadID, add: add, remove: remove)
        }
        await refreshFromServer(account: account, threadID: threadID)
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
            isUnread: message.isUnread,
            snippet: message.snippet
        )
    }

    nonisolated static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
