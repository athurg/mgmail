import Foundation

/// 报文拼装的自检。
///
/// 本该是单元测试，但这个项目按设计不依赖完整 Xcode（见 README），
/// 没有 XCTest 也没有 swift-testing 可用。所以做成一个独立可执行：
/// `Scripts/check_mime.sh` 把它和被检查的几个源文件一起编译跑一遍。
///
/// 盯的都是「本地看不出、收件人才看得出」的地方——报文拼错不会当场报错，
/// 是对方收到乱码、或者回信串不进原会话时才发现。
@main
struct MimeCheck {
    static var passed = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("第 \(line) 行：\(what)")
        }
    }

    // MARK: -

    static func makeMail(subject: String = "打个招呼", body: String = "你好") -> OutgoingMail {
        var mail = OutgoingMail(fromName: "冯建波", fromEmail: "me@example.com")
        mail.to = "张三 <zhang@example.com>"
        mail.subject = subject
        mail.body = body
        return mail
    }

    static func text(of mail: OutgoingMail) -> String {
        String(data: MimeBuilder.build(mail), encoding: .utf8) ?? ""
    }

    static func main() {
        headers()
        addresses()
        bodies()
        replyChain()
        attachments()
        overallShape()

        if failures.isEmpty {
            print("✓ \(passed) 项检查全部通过")
        } else {
            print("✗ \(failures.count) 项未通过（共 \(passed + failures.count) 项）：")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }

    // MARK: - 头部编码

    static func headers() {
        let chinese = text(of: makeMail(subject: "季度汇报"))
        expect(chinese.contains("Subject: =?UTF-8?B?"), "中文主题该按 RFC 2047 编码")
        expect(!chinese.contains("Subject: 季度汇报"), "编码后不该再留原文，否则对方看到乱码")
        let encoded = Data("季度汇报".utf8).base64EncodedString()
        expect(chinese.contains("=?UTF-8?B?\(encoded)?="), "编码内容该是主题的 base64")

        let ascii = text(of: makeMail(subject: "Weekly report"))
        expect(ascii.contains("Subject: Weekly report"), "纯 ASCII 主题不该平白编码")

        let mail = text(of: makeMail())
        expect(mail.contains("<zhang@example.com>"), "邮箱本身要原样保留")
        expect(mail.contains("From: =?UTF-8?B?"), "中文显示名要编码")
        expect(mail.contains("<me@example.com>"), "发件人邮箱要原样保留")
        expect(!mail.contains("Cc:"), "没填抄送就不该写这个头")
        expect(!mail.contains("Bcc:"), "没填密送就不该写这个头")
    }

    // MARK: - 地址拆分

    static func addresses() {
        expect(MimeBuilder.splitAddresses("a@x.com, b@y.com; c@z.com") == ["a@x.com", "b@y.com", "c@z.com"],
               "逗号和分号都该能拆")

        let quoted = MimeBuilder.splitAddresses("\"Doe, John\" <j@d.com>, b@y.com")
        expect(quoted.count == 2, "引号里的逗号不该拆")
        expect(quoted.first == "\"Doe, John\" <j@d.com>", "带引号的显示名要完整保留")

        expect(MimeBuilder.splitAddresses("").isEmpty, "空串不该产生地址")
        expect(MimeBuilder.splitAddresses("  ,  ; ").isEmpty, "只有分隔符不该产生空地址")
        expect(MimeBuilder.splitAddresses("a@x.com,,b@y.com").count == 2, "连续分隔符不该产生空地址")

        var empty = OutgoingMail(fromName: "我", fromEmail: "me@example.com")
        expect(!empty.canSend, "一个收件人都没有时不该让发")
        empty.to = "  "
        expect(!empty.canSend, "只有空白的收件人不算数")
        empty.bcc = "a@x.com"
        expect(empty.canSend, "只填密送也该算有收件人")
    }

    // MARK: - 正文

    static func bodies() {
        let raw = text(of: makeMail())
        expect(raw.contains("multipart/alternative"), "正文该发 plain + html 两份")
        if let plain = raw.range(of: "text/plain"), let html = raw.range(of: "text/html") {
            // MIME 规范里越靠后的候选优先级越高，HTML 必须排在 plain 之后
            expect(plain.lowerBound < html.lowerBound, "html 该排在 plain 后面，否则客户端优先显示纯文本")
        } else {
            expect(false, "两种正文类型都该在")
        }

        let body = "第一行\n第二行"
        expect(text(of: makeMail(body: body)).contains(Data(body.utf8).base64EncodedString()),
               "正文该能 base64 还原")

        let long = text(of: makeMail(body: String(repeating: "长", count: 400)))
        let lines = long.components(separatedBy: "\r\n")
        // 只挑纯 base64 字符的行：boundary 和带参数的头部行本来就可以更长
        let base64Lines = lines.filter { line in
            !line.isEmpty && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        }
        expect(base64Lines.allSatisfy { $0.count <= 76 }, "base64 该折行，单行不超过 76")
        expect(base64Lines.contains { $0.count == 76 }, "长正文确实该折出满行，否则上一条断言是空的")
        // RFC 5322 的硬上限，超了有些 MTA 会直接拒收
        expect(lines.allSatisfy { $0.count <= 998 }, "任何一行都不该超过 998 字符")

        let html = MimeBuilder.html(fromPlainText: "我的回复\n> 原文一\n> 原文二")
        expect(html.contains("<blockquote"), "引用行该变成 blockquote")
        expect(html.contains("</blockquote>"), "blockquote 该闭合")
        expect(html.contains("原文一"), "引用内容不该丢")

        let escaped = MimeBuilder.html(fromPlainText: "a < b && c > d")
        expect(escaped.contains("&lt;") && escaped.contains("&gt;") && escaped.contains("&amp;"),
               "正文里的尖括号和 & 该转义，不能变成标签")
    }

    // MARK: - 回复串会话

    static func replyChain() {
        var mail = makeMail()
        mail.inReplyTo = "<second@example.com>"
        mail.references = ["<first@example.com>", "<second@example.com>"]
        let raw = text(of: mail)
        expect(raw.contains("In-Reply-To: <second@example.com>"), "回复该带 In-Reply-To")
        expect(raw.contains("References: <first@example.com> <second@example.com>\r\n"),
               "已在链里的 id 不该重复追加")

        let fresh = text(of: makeMail())
        expect(!fresh.contains("In-Reply-To:"), "新邮件不该写 In-Reply-To")
        expect(!fresh.contains("References:"), "新邮件不该写 References")
    }

    // MARK: - 附件

    static func attachments() {
        var chinese = makeMail()
        chinese.attachments = [OutgoingAttachment(filename: "季度报表.pdf",
                                                  mimeType: "application/pdf",
                                                  data: Data("pdf".utf8))]
        let raw = text(of: chinese)
        expect(raw.contains("multipart/mixed"), "有附件该套一层 mixed")
        expect(raw.contains("Content-Disposition: attachment"), "附件该标成 attachment")
        expect(raw.contains("filename*=UTF-8''"), "中文文件名该走 RFC 2231")
        expect(!raw.contains("filename=\"季度报表.pdf\""), "退化的 ASCII 名里不该混进非 ASCII")

        var ascii = makeMail()
        ascii.attachments = [OutgoingAttachment(filename: "report.pdf",
                                                mimeType: "application/pdf",
                                                data: Data("pdf".utf8))]
        let plain = text(of: ascii)
        expect(plain.contains("filename=\"report.pdf\""), "ASCII 文件名原样写")
        expect(!plain.contains("filename*=UTF-8''"), "ASCII 文件名不必多带 RFC 2231 参数")

        expect(!text(of: makeMail()).contains("multipart/mixed"), "没附件就不该套 mixed")
    }

    // MARK: - 整体格式

    static func overallShape() {
        let raw = text(of: makeMail())
        expect(raw.contains("\r\n\r\n"), "头部和正文之间该空一行")
        // 裸 LF 会让部分 MTA 判成非法报文
        expect(!raw.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "行尾该一律 CRLF，不能有裸 LF")

        let dated = String(data: MimeBuilder.build(makeMail(), date: Date(timeIntervalSince1970: 0)),
                           encoding: .utf8) ?? ""
        expect(dated.contains("Date: Thu, 1 Jan 1970"), "Date 头该是 RFC 2822 格式且不随系统区域变")
    }
}
