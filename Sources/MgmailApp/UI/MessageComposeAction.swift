import SwiftUI

/// 从正在查看的一封邮件开出撰写窗口：算出撰写窗口的值（nil 表示这封邮件开不出来）。
///
/// 主窗口右栏和双击弹出的独立窗口共用这一套规则：
/// - 回复/转发接的是会话里**最后一封**：一串会话里用户想接的总是最新那条；
/// - 发件人按这封邮件所属账号在**全部**账号里找——独立窗口可能在切换分组之后还开着，
///   那时它的账号已经不在当前分组里了。
@MainActor
enum MessageComposeAction {
    static func windowValue(_ kind: ComposeKind, model: MessageDetailModel,
                            accounts: [Account]) -> UUID? {
        guard let message = model.messages.last,
              let accountID = model.account, let threadID = model.threadID,
              let account = accounts.first(where: { $0.id == accountID })
        else { return nil }

        switch kind {
        case .reply(let all):
            return ComposeStore.shared.reply(to: message, account: account,
                                             threadID: threadID, all: all,
                                             quotedBody: MailQuote.reply(to: message))
        case .forward:
            return ComposeStore.shared.forward(message, account: account,
                                               sourceAccount: accountID,
                                               quotedBody: MailQuote.forward(message))
        case .new:
            return ComposeStore.shared.newMail(from: account)
        }
    }
}
