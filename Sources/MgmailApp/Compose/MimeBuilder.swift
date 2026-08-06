import Foundation

/// 把撰写内容拼成一封 RFC 2822 报文——`messages.send` 要的就是这个。
///
/// 有三处不拼对就会出洋相，都在这里集中处理：
///
/// - **头部里的非 ASCII**（中文主题、中文显示名）必须按 RFC 2047 编码成
///   `=?UTF-8?B?…?=`，直接塞原文对方看到的就是乱码。地址头只编码显示名，
///   尖括号里的邮箱本身永远是 ASCII，编了反而寄不出去。
/// - **正文一律 base64**。quoted-printable 更省字节，但软换行、行尾空格、
///   等号转义几条规则都容易写错，而正文本来就要整段传，省这点字节不划算。
/// - **附件文件名**用 RFC 2231 的 `filename*=UTF-8''…`，中文名才不会散架。
enum MimeBuilder {
    /// 拼出完整报文。
    static func build(_ mail: OutgoingMail, date: Date = Date()) -> Data {
        var head = ""
        head += headerLine("From", addressList(mail.fromDisplay))
        if let to = optionalList(mail.to) { head += headerLine("To", to) }
        if let cc = optionalList(mail.cc) { head += headerLine("Cc", cc) }
        // Bcc 写进报文里，Gmail 收到后会替我们剥掉，不会漏给收件人
        if let bcc = optionalList(mail.bcc) { head += headerLine("Bcc", bcc) }
        head += headerLine("Subject", encodeHeaderText(mail.subject))
        head += headerLine("Date", rfc2822Date(date))
        head += headerLine("MIME-Version", "1.0")
        if let inReplyTo = mail.inReplyTo {
            head += headerLine("In-Reply-To", inReplyTo)
            // References 是整条链，收尾接上被回复的这封
            let chain = (mail.references + [inReplyTo]).uniqued()
            head += headerLine("References", chain.joined(separator: " "))
        }

        return Data((head + bodySection(mail)).utf8)
    }

    // MARK: - 正文

    /// 正文永远发 plain + html 两份：纯文本保底，HTML 让换行和引用块在
    /// 主流客户端里显示得体。有附件时再在外面套一层 mixed。
    private static func bodySection(_ mail: OutgoingMail) -> String {
        let alternative = alternativeSection(text: mail.body)
        guard !mail.attachments.isEmpty else { return alternative }

        let boundary = makeBoundary()
        var s = headerLine("Content-Type", "multipart/mixed; boundary=\"\(boundary)\"")
        s += CRLF
        s += "--\(boundary)" + CRLF
        s += alternative
        for attachment in mail.attachments {
            s += CRLF + "--\(boundary)" + CRLF
            s += attachmentSection(attachment)
        }
        s += CRLF + "--\(boundary)--" + CRLF
        return s
    }

    /// multipart/alternative：同一段内容的纯文本版和 HTML 版。
    /// 顺序有讲究——按 MIME 规范，越靠后的越优先，所以 HTML 必须放在后面。
    private static func alternativeSection(text: String) -> String {
        let boundary = makeBoundary()
        var s = headerLine("Content-Type", "multipart/alternative; boundary=\"\(boundary)\"")
        s += CRLF

        s += "--\(boundary)" + CRLF
        s += headerLine("Content-Type", "text/plain; charset=UTF-8")
        s += headerLine("Content-Transfer-Encoding", "base64")
        s += CRLF
        s += base64Body(text)

        s += CRLF + "--\(boundary)" + CRLF
        s += headerLine("Content-Type", "text/html; charset=UTF-8")
        s += headerLine("Content-Transfer-Encoding", "base64")
        s += CRLF
        s += base64Body(html(fromPlainText: text))

        s += CRLF + "--\(boundary)--" + CRLF
        return s
    }

    private static func attachmentSection(_ attachment: OutgoingAttachment) -> String {
        var s = headerLine("Content-Type", "\(attachment.mimeType); name=\"\(asciiFilename(attachment.filename))\"")
        s += headerLine("Content-Transfer-Encoding", "base64")
        s += headerLine("Content-Disposition", "attachment; " + filenameParameter(attachment.filename))
        s += CRLF
        s += wrap(attachment.data.base64EncodedString())
        return s
    }

    /// 纯文本转 HTML：转义、换行变 `<br>`，`>` 开头的引用行套上左边线。
    static func html(fromPlainText text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var out = ""
        var quoting = false
        for line in lines {
            let isQuote = line.hasPrefix(">")
            if isQuote && !quoting {
                out += "<blockquote style=\"margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex;color:#555\">"
                quoting = true
            } else if !isQuote && quoting {
                out += "</blockquote>"
                quoting = false
            }
            let content = isQuote ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            out += escapeHTML(content) + "<br>"
        }
        if quoting { out += "</blockquote>" }
        return "<div style=\"font-family:-apple-system,'Helvetica Neue',sans-serif;font-size:14px\">\(out)</div>"
    }

    // MARK: - 地址

    /// 按逗号拆地址，但不拆引号和尖括号里的逗号——
    /// `"Doe, John" <j@d.com>` 是**一个**收件人，粗暴 split 会把它劈成两半。
    static func splitAddresses(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in raw {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "<":
                inAngle = true
                current.append(ch)
            case ">":
                inAngle = false
                current.append(ch)
            case "," where !inQuotes && !inAngle, ";" where !inQuotes && !inAngle:
                result.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        result.append(current)
        return result
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 把一串输入拼成合法的地址头值；没有有效地址时返回 nil，调用方就不写这个头。
    private static func optionalList(_ raw: String) -> String? {
        let items = splitAddresses(raw)
        guard !items.isEmpty else { return nil }
        return items.map { addressList(EmailAddress(header: $0)) }.joined(separator: ", ")
    }

    /// 单个地址：显示名要编码，邮箱本身原样。
    private static func addressList(_ address: EmailAddress) -> String {
        guard address.name != address.email, !address.name.isEmpty else { return address.email }
        return "\(encodeHeaderText(address.name)) <\(address.email)>"
    }

    // MARK: - 编码

    private static let CRLF = "\r\n"

    private static func headerLine(_ name: String, _ value: String) -> String {
        "\(name): \(value)" + CRLF
    }

    /// RFC 2047：整段编成一个 base64 词。纯 ASCII 就原样返回，免得平白变难读。
    static func encodeHeaderText(_ text: String) -> String {
        guard text.contains(where: { !$0.isASCII }) else { return text }
        let encoded = Data(text.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    private static func base64Body(_ text: String) -> String {
        wrap(Data(text.utf8).base64EncodedString())
    }

    /// base64 按 76 字符折行（RFC 2045 要求不超过 998，76 是惯例）。
    private static func wrap(_ base64: String, at width: Int = 76) -> String {
        var out = ""
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: width, limitedBy: base64.endIndex) ?? base64.endIndex
            out += base64[index..<end] + CRLF
            index = end
        }
        return out
    }

    /// RFC 2231：中文文件名走 `filename*=UTF-8''…`，同时留一个退化的 ASCII 名给老客户端。
    private static func filenameParameter(_ filename: String) -> String {
        let ascii = asciiFilename(filename)
        guard filename.contains(where: { !$0.isASCII }) else { return "filename=\"\(ascii)\"" }
        let escaped = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        return "filename=\"\(ascii)\"; filename*=UTF-8''\(escaped)"
    }

    /// 退化用的 ASCII 文件名：非 ASCII 字符换成下划线，引号去掉免得把参数值提前闭合。
    private static func asciiFilename(_ filename: String) -> String {
        let cleaned = filename.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? $0 : "_" }
        return String(cleaned)
    }

    private static func makeBoundary() -> String {
        "----=_Mgmail_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private static func rfc2822Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension OutgoingMail {
    var fromDisplay: EmailAddress {
        EmailAddress(name: fromName, email: fromEmail)
    }
}

private extension Array where Element: Hashable {
    /// 去重但保持顺序（References 链不能乱序）。
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
