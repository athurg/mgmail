import SwiftUI

enum ComposeWindow {
    static let id = "compose"
}

/// 撰写窗口的初始内容。
///
/// 窗口本身只认一个 UUID——SwiftUI 的 `WindowGroup(for:)` 要求窗口值是可编码的
/// 小标识，整封邮件塞不进去。所以开窗前先把内容存这儿，窗口起来后凭 id 领走，
/// 之后编辑状态就归窗口自己的 `ComposeModel` 管，这里不再掺和。
@MainActor
final class ComposeStore: ObservableObject {
    static let shared = ComposeStore()

    struct Seed {
        let kind: ComposeKind
        let mail: OutgoingMail
    }

    private var seeds: [UUID: Seed] = [:]

    func register(_ seed: Seed) -> UUID {
        let id = UUID()
        seeds[id] = seed
        return id
    }

    func seed(_ id: UUID) -> Seed? { seeds[id] }

    /// 窗口关掉就把种子丢了，免得越攒越多。
    func discard(_ id: UUID) { seeds.removeValue(forKey: id) }

    // MARK: - 几种来路

    func newMail(from account: Account) -> UUID {
        register(Seed(kind: .new, mail: OutgoingMail(fromName: account.displayName,
                                                     fromEmail: account.email)))
    }

    /// 回复。`all` 为真时把原收件人也一并带上（去掉自己）。
    func reply(to message: RenderedMessage, account: Account, threadID: String,
               all: Bool, quotedBody: String) -> UUID {
        var mail = OutgoingMail(fromName: account.displayName, fromEmail: account.email)
        mail.to = message.fromEmail
        if all {
            // 原收件人里剔掉自己，否则回复一次就给自己抄送一份
            let others = MimeBuilder.splitAddresses(message.to)
                .map { EmailAddress(header: $0) }
                .filter { $0.email.caseInsensitiveCompare(account.email) != .orderedSame }
                .filter { $0.email.caseInsensitiveCompare(message.fromEmail) != .orderedSame }
            mail.cc = others.map(\.email).joined(separator: ", ")
        }
        mail.subject = prefixed(message.subject, with: "Re:")
        mail.body = "\n\n" + quotedBody
        mail.threadID = threadID
        mail.inReplyTo = message.messageIDHeader
        mail.references = message.referencesHeader ?? []
        return register(Seed(kind: .reply(all: all), mail: mail))
    }

    /// 转发。不预填收件人，也不接进原会话——转发是另起一串。
    func forward(_ message: RenderedMessage, account: Account, quotedBody: String) -> UUID {
        var mail = OutgoingMail(fromName: account.displayName, fromEmail: account.email)
        mail.subject = prefixed(message.subject, with: "Fwd:")
        mail.body = "\n\n" + quotedBody
        return register(Seed(kind: .forward, mail: mail))
    }

    /// 主题加前缀。已经有了就不再叠——「Re: Re: Re:」是邮件客户端最没必要的产出。
    private func prefixed(_ subject: String, with prefix: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        guard !trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return trimmed }
        return "\(prefix) \(trimmed)"
    }
}
