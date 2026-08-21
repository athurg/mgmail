import Foundation

/// 渲染用的单封邮件视图模型。
struct RenderedMessage: Codable, Identifiable {
    let id: String
    let fromName: String
    let fromEmail: String
    let to: String
    /// 抄送。可选以兼容旧缓存解码（旧缓存另有版本号挡着，见 `CachedThread`）。
    let cc: String?
    /// 密送。收到的信里几乎不会有——它只留在自己发出去的那一份上，
    /// 所以「已发送」里看得到，收件箱里看不到，这不是漏了。
    let bcc: String?
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

    /// 信头上要摆哪几行收件人。空的不占位——没有抄送的信不该多出一行「抄送：」。
    ///
    /// 「摆哪几行、什么顺序、叫什么名字」只在这里定一次：右栏卡片和独立窗口的信头
    /// 长得不一样（一个是紧凑的一行行，一个是对齐成两列的 Grid），但摆的内容得是同一份。
    var recipientFields: [RecipientField] {
        [("收件人", to, false), ("抄送", cc ?? "", false), ("密送", bcc ?? "", true)]
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { RecipientField(label: $0.0, value: $0.1, isBlind: $0.2) }
    }

    /// 返回替换了正文的副本。
    func withBody(_ html: String) -> RenderedMessage {
        RenderedMessage(id: id, fromName: fromName, fromEmail: fromEmail, to: to, cc: cc, bcc: bcc,
                        date: date, subject: subject, bodyHTML: html, attachments: attachments,
                        snippet: snippet, messageIDHeader: messageIDHeader,
                        referencesHeader: referencesHeader)
    }
}

/// 信头上的一行收件人（收件人 / 抄送 / 密送）。
struct RecipientField: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    /// 密送这一行。自己看没问题，但**不能跟着信走**——转发时把它抄进引用块，
    /// 就等于当着新收件人的面把当初悄悄抄送的人全点了名。
    let isBlind: Bool
}

/// 取一封邮件（或一串会话）的正文：拉取 → 渲染 → 把内联图换成 data URI → 落缓存。
///
/// 用户点开邮件走这条路，定时同步的正文预取（`BodyPrefetch`）也走这条路——
/// 正文是不可变的，谁先取到都一样，差别只在**什么时候**取。写成两处的话，
/// 「内联图没换全就不落盘」这类规矩迟早会在两边分家。
enum MessageBodyLoader {
    /// 一次取回的结果。
    struct Loaded {
        let thread: CachedThread
        /// 内联图片是不是全换下来了。没换全的不落盘，见 `load`。
        let complete: Bool
    }

    /// 从服务器取正文并渲染；内联图片齐了才写进缓存。正文本身一次请求拿完。
    ///
    /// 有内联图没换下来就先不落盘：正文缓存是「一辈子只拉一次」的，这时候存进去，
    /// 一次网络抖动造成的破图就再也没机会修好了。渲染结果照样返回——
    /// 界面拿它显示没问题，只是下次打开会再拉一次。
    static func load(account: String, threadID: String, conversation: Bool) async throws -> Loaded {
        let api = GmailAPI(account: account)
        let raw: [GmailMessage]
        if conversation {
            raw = try await api.getThread(id: threadID, format: "full").messages ?? []
        } else {
            raw = [try await api.getMessage(id: threadID, format: "full")]
        }

        // 先把内联图片全部解析好再一次性交出去，避免出现「原始 cid → 解析后」的中间态闪烁
        var rendered = raw.map { render($0) }
        let complete: Bool
        (rendered, complete) = await resolveInline(rendered, rawMessages: raw, account: account)

        let thread = CachedThread(subject: rendered.first?.subject ?? "（无主题）", messages: rendered)

        if complete {
            await MailCache.shared.saveThread(thread, account: account, threadID: threadID,
                                              conversation: conversation)
        }
        return Loaded(thread: thread, complete: complete)
    }

    /// 把正文里的 `cid:` 内联图片替换为 data URI；优先用缓存，缺失才下载并缓存。
    ///
    /// 第二个返回值是「有没有全换下来」。有一张没换成，这份正文就不该进缓存——
    /// 详见 `load` 里落盘前的那道判断。
    private static func resolveInline(_ rendered: [RenderedMessage], rawMessages: [GmailMessage],
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

    static func render(_ message: GmailMessage) -> RenderedMessage {
        let fromHeader = MimeParser.header(message.payload, "From") ?? ""
        let from = EmailAddress(header: fromHeader)
        let to = MimeParser.header(message.payload, "To") ?? ""
        let cc = MimeParser.header(message.payload, "Cc")
        let bcc = MimeParser.header(message.payload, "Bcc")
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
            cc: cc,
            bcc: bcc,
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

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
