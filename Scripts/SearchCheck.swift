import Foundation

/// 本地搜索的自检。
///
/// 和 `MailboxCheck` 同一个路数（项目不依赖完整 Xcode，见 README），
/// 由 `Scripts/check_search.sh` 把 `MailSearch.swift` 单独编出来跑。
///
/// 盯的是搜索最容易「悄悄搜错」的那几处：一个词都没打完就把列表清空、
/// 中文输入法打出来的全角冒号不认、带冒号的网址被当成限定词、
/// 显示名挡住了发件人地址。这些都不会报错，只会让人以为邮件不见了。
@main
struct SearchCheck {
    static var passed = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("第 \(line) 行：\(what)")
        }
    }

    /// 攒一封邮件。传的都是原文，折叠由 `SearchableText` 自己做——
    /// 这正是应用里的走法，测的也该是这条路。
    static func mail(from: String, email: String, subject: String, snippet: String,
                     labels: [String] = [], attachment: Bool = false) -> SearchableMail {
        SearchableMail(text: SearchableText(from: from, fromEmail: email,
                                            subject: subject, snippet: snippet),
                       labelIds: labels, hasAttachment: attachment)
    }

    /// 一封样板邮件：带附件的未读会议纪要。
    static let mail = mail(
        from: "José Álvarez",
        email: "jose@Example.COM",
        subject: "周四的会议纪要",
        snippet: "附件是这次的 Q3 预算表，请过目。",
        labels: ["INBOX", "UNREAD"],
        attachment: true
    )

    /// 一封对照组：已读、加星、没附件、别人发的。
    static let other = mail(
        from: "billing",
        email: "no-reply@shop.cn",
        subject: "您的订单已发货",
        snippet: "订单号 20240711，预计周四送达。",
        labels: ["INBOX", "STARRED"]
    )

    static func hit(_ query: String, _ mail: SearchableMail = mail) -> Bool {
        MailSearchQuery.parse(query).matches(mail)
    }

    static func main() {
        plainWords()
        insensitivity()
        folding()
        phrases()
        fields()
        halfTypedQueries()
        notAField()

        if failures.isEmpty {
            print("✓ \(passed) 项检查全部通过")
        } else {
            print("✗ \(failures.count) 项未通过（共 \(passed + failures.count) 项）：")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }

    // MARK: - 裸词：发件人（名字和地址）、主题、摘要，任一命中

    static func plainWords() {
        expect(MailSearchQuery.parse("").isEmpty, "空输入不是搜索，列表照旧显示全部")
        expect(MailSearchQuery.parse("   ").isEmpty, "只打了空格也不算搜索")

        expect(hit("Álvarez"), "搜发件人名字")
        expect(hit("会议纪要"), "搜主题")
        expect(hit("预算表"), "搜摘要")
        // 显示名里根本没有地址，「搜某个域名来的信」全靠这一条
        expect(hit("example.com"), "搜发件人地址")
        expect(!hit("发货"), "别的邮件的主题不该命中这一封")

        // 多个词是「且」：各自命中不同字段也算数
        expect(hit("会议 预算"), "两个词分别命中主题和摘要")
        expect(!hit("会议 发货"), "有一个词没命中就整封不算")
    }

    // MARK: - 大小写 / 变音符号 / 全半角都不该拦人

    static func insensitivity() {
        expect(hit("EXAMPLE.COM"), "大小写不计较")
        expect(hit("jose"), "变音符号不计较：jose 找得到 José")
        expect(hit("JOSÉ"), "两样一起来也认")
        // 中文输入法下打出来的字母数字是全角的，看起来一模一样
        expect(hit("Ｑ３"), "全角输入找得到半角原文")
    }

    // MARK: - 引号短语

    static func phrases() {
        expect(hit("\"周四的会议\""), "引号里的空格不拆词")
        expect(hit("“周四的会议”"), "中文引号一样认")
        expect(!hit("\"预算 会议\""), "短语要整段对上，顺序不同不算")
        // 右引号还没打出来的时候，前面那半截照样得能搜
        expect(hit("\"周四的会议"), "缺右引号也照搜，边打字边出结果")
    }

    // MARK: - 折叠：两头都折过一遍，比较本身才敢不带 option

    static func folding() {
        // 邮件那头折了、查询词那头也折了，才有下面这些等价
        expect(hit("JOSE ALVAREZ"), "查询词的大写和缺失的变音符号都不挡路")
        expect(hit("from:JOSÉ"), "限定词的值同样折过")
        expect(MailSearchQuery.fold("José Ｑ３") == MailSearchQuery.fold("jose Q3"),
               "折叠把大小写、变音、全半角碾平到同一个样子")
        expect(MailSearchQuery.fold("已读") == "已读", "中文不受折叠影响")
    }

    // MARK: - 限定词

    static func fields() {
        expect(hit("from:jose"), "from: 限定发件人")
        expect(hit("from:example.com"), "from: 也认地址")
        expect(!hit("from:会议纪要"), "from: 不该搜到主题里去")
        expect(hit("subject:会议"), "subject: 限定主题")
        expect(!hit("subject:预算"), "subject: 不该搜到摘要里去")
        expect(hit("from:\"José Álvarez\""), "限定词后面可以跟引号短语")
        expect(hit("发件人：jose"), "中文限定词加全角冒号——中文输入法下最常打出来的样子")

        expect(hit("is:unread"), "is:unread 认未读")
        expect(!hit("is:read"), "未读的信不该被 is:read 收走")
        expect(hit("is:read", other), "读过的信归 is:read")
        expect(hit("is:starred", other), "is:starred 认星标")
        expect(!hit("is:starred"), "没加星的不算")
        expect(hit("has:attachment"), "has:attachment 认附件")
        expect(!hit("has:attachment", other), "没附件的不算")

        // 限定词之间同样是「且」，也能和裸词混用
        expect(hit("is:unread has:attachment 会议"), "限定词和裸词混着用")
        expect(!hit("is:unread is:starred"), "两个状态都要满足，缺一不可")
    }

    // MARK: - 打到一半的输入，不该让列表当场空掉

    static func halfTypedQueries() {
        expect(MailSearchQuery.parse("from:").isEmpty, "「from:」还没写完，先当没搜")
        expect(MailSearchQuery.parse("is:").isEmpty, "「is:」同理")
        expect(hit("from: 会议"), "写了一半的限定词不该把后面那个词也拖下水")
        expect(MailSearchQuery.parse("\"\"").isEmpty, "空引号里什么都没有")
    }

    // MARK: - 认不出来的限定词按字面量搜

    static func notAField() {
        // 搜一个带冒号的网址是很常见的事，当成限定词就会一封都搜不到
        let link = mail(from: "n", email: "n@x.com", subject: "见 https://a.cn", snippet: "")
        expect(hit("https://a.cn", link), "带冒号的网址按字面量搜")
        expect(!hit("is:whatever"), "认不出的 is: 值不该反而把整封放行")
        expect(hit("\"from:jose\"", mail(from: "n", email: "n@x.com",
                                         subject: "from:jose 是什么意思", snippet: "")),
               "加了引号的限定词是字面量")
    }
}
