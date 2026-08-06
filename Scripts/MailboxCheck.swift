import Foundation

/// 邮箱归属判断的自检。
///
/// 和 `MimeCheck` 同一个路数（项目不依赖完整 Xcode，见 README），
/// 由 `Scripts/check_mailbox.sh` 把 `Mailbox.swift` 单独编出来跑。
///
/// 盯的是「本地看着没错、和 Gmail 一比才发现不对」的地方：删除和标记垃圾
/// 在 Gmail 里只是加个标签，SENT、STARRED、用户标签一个都不会掉。
/// 不把它们排除掉，删过的信就会赖在「已发送」里不走。
@main
struct MailboxCheck {
    static var passed = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("第 \(line) 行：\(what)")
        }
    }

    /// 某个邮箱收不收下这组标签。
    static func belongs(_ mailbox: String, _ labels: [String]) -> Bool {
        MailboxQuery.resolve(labelID: mailbox).labelsBelong(labels)
    }

    static func main() {
        normalMail()
        discardedMail()
        trashAndSpamThemselves()
        apiParameters()

        if failures.isEmpty {
            print("✓ \(passed) 项检查全部通过")
        } else {
            print("✗ \(failures.count) 项未通过（共 \(passed + failures.count) 项）：")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }

    // MARK: - 正常的信该在它该在的地方

    static func normalMail() {
        expect(belongs("INBOX", ["INBOX", "UNREAD"]), "收件箱的信在收件箱里")
        expect(belongs("SENT", ["SENT"]), "发出去的信在已发送里")
        expect(belongs("STARRED", ["STARRED", "INBOX"]), "加星的信在星标里")
        expect(belongs("ALL_MAIL", ["SENT"]), "所有邮件收下一切没被丢弃的")
        expect(belongs("Label_12", ["Label_12", "INBOX"]), "打了标签的信在该标签下")
        expect(belongs("CATEGORY_UPDATES", ["CATEGORY_UPDATES", "INBOX"]), "分类标签同理")

        expect(!belongs("INBOX", ["SENT"]), "没有 INBOX 标签就不在收件箱")
        expect(!belongs("STARRED", ["INBOX"]), "没加星就不在星标里")
        expect(!belongs("Label_12", ["Label_99", "INBOX"]), "别人的标签不算数")
    }

    // MARK: - 丢进废纸篓/垃圾邮件的，别处就不该再出现

    static func discardedMail() {
        for box in ["INBOX", "SENT", "STARRED", "ALL_MAIL", "Label_12", "CATEGORY_UPDATES"] {
            let labels = [box == "ALL_MAIL" ? "SENT" : box, "TRASH"]
            expect(!belongs(box, labels), "\(box)：进了废纸篓就不该还在这儿")
            let spam = [box == "ALL_MAIL" ? "SENT" : box, "SPAM"]
            expect(!belongs(box, spam), "\(box)：标成垃圾邮件就不该还在这儿")
        }
        // 最容易被忽略的一条：删掉的已发送邮件，SENT 标签是不会掉的
        expect(!belongs("SENT", ["SENT", "TRASH"]), "删掉的已发送邮件不该赖在已发送里")
        expect(!belongs("STARRED", ["STARRED", "SPAM"]), "加过星的垃圾邮件不该留在星标里")
    }

    // MARK: - 废纸篓和垃圾邮件自己是终点，不能自我排除

    static func trashAndSpamThemselves() {
        expect(belongs("TRASH", ["TRASH", "SENT"]), "废纸篓里就该看得见废纸篓的信")
        expect(belongs("SPAM", ["SPAM"]), "垃圾邮件里就该看得见垃圾邮件")
        expect(belongs("TRASH", ["TRASH", "SPAM"]), "两个标签都有时废纸篓照样收")
        expect(!belongs("TRASH", ["INBOX"]), "没被删的信不在废纸篓里")
        expect(!belongs("SPAM", ["INBOX"]), "不是垃圾的信不在垃圾邮件里")
    }

    // MARK: - 传给 Gmail 的拉取参数

    static func apiParameters() {
        expect(MailboxQuery.resolve(labelID: "ALL_MAIL").apiLabelID == nil,
               "所有邮件不按标签过滤")
        expect(MailboxQuery.resolve(labelID: "INBOX").apiLabelID == "INBOX",
               "收件箱按 INBOX 过滤")
        // 按 SPAM/TRASH 过滤时必须显式开启，否则 Gmail 一封都不返回
        expect(MailboxQuery.resolve(labelID: "TRASH").includeSpamTrash, "拉废纸篓要开 includeSpamTrash")
        expect(MailboxQuery.resolve(labelID: "SPAM").includeSpamTrash, "拉垃圾邮件要开 includeSpamTrash")
        expect(!MailboxQuery.resolve(labelID: "INBOX").includeSpamTrash, "拉收件箱不必开")

        expect(MailboxQuery.needsExplicitFetch(labelID: "TRASH"), "废纸篓要单独拉")
        expect(MailboxQuery.needsExplicitFetch(labelID: "SPAM"), "垃圾邮件要单独拉")
        expect(!MailboxQuery.needsExplicitFetch(labelID: "INBOX"), "收件箱在账户级返回范围内")
    }
}
