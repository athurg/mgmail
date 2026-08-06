import Foundation

/// 从 Gmail 邮件的 payload 中提取正文与附件。
enum MimeParser {
    /// base64url 解码（Gmail 的 body.data 用 URL-safe 无填充 base64）。
    static func decodeBase64URL(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// 提取正文：优先 text/html，退化到 text/plain。
    static func extractBody(_ payload: MessagePart?) -> (html: String?, text: String?) {
        guard let payload else { return (nil, nil) }
        var html: String?
        var text: String?
        walk(payload) { part in
            guard part.filename?.isEmpty ?? true else { return } // 有文件名的是附件，跳过
            guard let mime = part.mimeType?.lowercased(),
                  let data = part.body?.data,
                  let decoded = decodeBase64URL(data),
                  let str = String(data: decoded, encoding: .utf8) else { return }
            if mime == "text/html", html == nil {
                html = str
            } else if mime == "text/plain", text == nil {
                text = str
            }
        }
        return (html, text)
    }

    /// 收集附件（filename 非空且带 attachmentId 的 part）。
    static func attachments(_ payload: MessagePart?, messageID: String) -> [Attachment] {
        guard let payload else { return [] }
        var result: [Attachment] = []
        walk(payload) { part in
            guard let filename = part.filename, !filename.isEmpty,
                  let attachmentId = part.body?.attachmentId else { return }
            result.append(Attachment(
                messageID: messageID,
                attachmentId: attachmentId,
                filename: filename,
                mimeType: part.mimeType ?? "application/octet-stream",
                size: part.body?.size ?? 0
            ))
        }
        return result
    }

    /// 从 headers 里取某个字段（大小写不敏感）。
    static func header(_ payload: MessagePart?, _ name: String) -> String? {
        payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    /// 内联图片（带 Content-ID 且有 attachmentId 的 part），用于把 cid: 引用替换成 data URI。
    struct InlineImage {
        let contentID: String       // 去掉尖括号后的 cid
        let attachmentId: String
        let mimeType: String
    }

    static func inlineImages(_ payload: MessagePart?) -> [InlineImage] {
        guard let payload else { return [] }
        var result: [InlineImage] = []
        walk(payload) { part in
            guard let attachmentId = part.body?.attachmentId,
                  let cidRaw = part.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value
            else { return }
            let cid = cidRaw.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            guard !cid.isEmpty else { return }
            result.append(InlineImage(
                contentID: cid,
                attachmentId: attachmentId,
                mimeType: part.mimeType ?? "application/octet-stream"
            ))
        }
        return result
    }

    // 递归遍历所有 part。
    private static func walk(_ part: MessagePart, _ visit: (MessagePart) -> Void) {
        visit(part)
        for child in part.parts ?? [] {
            walk(child, visit)
        }
    }
}

/// 解析 From 头，拆出显示名与邮箱。
struct EmailAddress {
    let name: String
    let email: String

    init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// 解析形如 `"张三" <a@b.com>` 或 `a@b.com`。
    init(header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if let lt = trimmed.lastIndex(of: "<"), let gt = trimmed.lastIndex(of: ">"), lt < gt {
            let email = String(trimmed[trimmed.index(after: lt)..<gt])
            var name = String(trimmed[trimmed.startIndex..<lt])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if name.isEmpty { name = email }
            self.name = name
            self.email = email
        } else {
            self.name = trimmed
            self.email = trimmed
        }
    }

    /// 显示用短名称（去掉邮箱域名的粗略展示）。
    var display: String { name }
}
