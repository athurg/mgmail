import AppKit

/// 把原邮件变成回复/转发里的引用块。
///
/// 原文是 HTML，而撰写框是纯文本，中间得过一道。转换借 `NSAttributedString`
/// 的 HTML 解析——自己拿正则剥标签，遇到 `<style>`、表格、被转义的实体
/// 就会露馅，而这个能力系统本来就有。
enum MailQuote {
    /// 回复：一行「某某 在 某时 写道：」，其后每行前面加 `>`。
    @MainActor
    static func reply(to message: RenderedMessage) -> String {
        let head = "在 \(message.dateText)，\(message.fromName) <\(message.fromEmail)> 写道："
        return head + "\n" + quoted(plainText(of: message))
    }

    /// 转发：原样附上，加一段头信息，不加 `>` 前缀（转发是「递过去」而不是「引述」）。
    @MainActor
    static func forward(_ message: RenderedMessage) -> String {
        var head = "---------- 转发的邮件 ----------\n"
        head += "发件人：\(message.fromName) <\(message.fromEmail)>\n"
        head += "日期：\(message.dateText)\n"
        head += "主题：\(message.subject)\n"
        // 密送不进引用块：转发出去就等于把当初悄悄抄送的人当众点名（见 `RecipientField`）
        for field in message.recipientFields where !field.isBlind {
            head += "\(field.label)：\(field.value)\n"
        }
        return head + "\n" + plainText(of: message)
    }

    /// 每行加 `>` 前缀。
    private static func quoted(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    /// HTML 转纯文本。解析失败就退回原串——宁可让用户看到一堆标签，
    /// 也好过引用块整个空掉、回信里看不出在回什么。
    @MainActor
    static func plainText(of message: RenderedMessage) -> String {
        guard let data = message.bodyHTML.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              )
        else { return message.bodyHTML }

        return attributed.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            // HTML 转出来常带一长串空行，压成最多一个空行
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
