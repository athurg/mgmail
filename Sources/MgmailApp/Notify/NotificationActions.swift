import Foundation
import UserNotifications

/// 新邮件通知横幅上的快捷操作。
///
/// 三个动作都不带 `.foreground`——重点就是不用切到应用：横幅上按一下，
/// 邮件就处理掉了，人还在原来那件事上。
enum NotificationAction: String, CaseIterable {
    case markRead = "mail.action.markRead"
    case archive = "mail.action.archive"
    case trash = "mail.action.trash"

    var title: String {
        switch self {
        case .markRead: return "标记为已读"
        case .archive: return "归档"
        case .trash: return "删除"
        }
    }

    var options: UNNotificationActionOptions {
        // 删除标红，和系统里其他破坏性动作一致
        self == .trash ? [.destructive] : []
    }

    /// 带快捷操作的单封新邮件通知所属的分类。
    /// 汇总通知（「12 封新邮件」）不用它——那条没有确定的落点，无从操作。
    static let categoryID = "mail.new"

    /// 把分类注册进通知中心。必须在投递任何通知之前完成，否则横幅上不会有按钮。
    @MainActor
    static func registerCategory() {
        guard NotificationPermission.isAvailable else { return }
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: allCases.map {
                UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: $0.options)
            },
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// 执行通知里点下的那个快捷操作。
///
/// 与列表里的同名操作走的是同一套 Gmail 调用，区别在于**本地池子可能还不在**：
/// 应用没运行时点按钮，系统会先把进程拉起来，此刻 `MailStore` 还没从磁盘恢复。
/// 所以请求照发，本地更新是尽力而为——池子回来之后，下一轮同步自然对齐。
@MainActor
final class NotificationActionHandler {
    static let shared = NotificationActionHandler()

    /// 由 `RootView` 注入。弱引用：它的所有者是 App，不该被这里续命。
    weak var store: MailStore?

    private init() {}

    /// 通知里的操作按会话还是按单封走，跟着列表的显示设置——
    /// 用户看到的是一行会话，归档就该归档整串。
    private var conversation: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.conversationView)
    }

    func perform(_ action: NotificationAction, route: NotificationRoute) async {
        guard let messageID = route.messageID, let threadID = route.threadID else { return }
        let byConversation = conversation
        let targetID = byConversation ? threadID : messageID
        let account = route.account

        let affected = applyLocally(action, account: account, messageID: messageID, threadID: threadID)

        do {
            let api = GmailAPI(account: account)
            switch action {
            case .markRead:
                if byConversation {
                    try await api.modifyThread(id: targetID, remove: ["UNREAD"])
                } else {
                    try await api.modifyMessage(id: targetID, remove: ["UNREAD"])
                }
            case .archive:
                if byConversation {
                    try await api.modifyThread(id: targetID, remove: ["INBOX"])
                } else {
                    try await api.modifyMessage(id: targetID, remove: ["INBOX"])
                }
            case .trash:
                if byConversation {
                    try await api.trashThread(id: targetID)
                } else {
                    try await api.trashMessage(id: targetID)
                }
            }
        } catch {
            // 本地已经先改了，失败就得改回来——拿服务器的状态覆盖
            await store?.revalidate(account: account, messageIDs: affected)
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            report("\(action.title)失败：\(reason)")
        }
    }

    /// 乐观更新本地池子；池子还没恢复时返回空，那就纯粹靠请求本身。
    /// 返回被改动的邮件 id，失败回滚时要用。
    private func applyLocally(_ action: NotificationAction, account: String,
                              messageID: String, threadID: String) -> [String] {
        guard let store else { return [] }
        // 池子还没恢复（冷启动就点了按钮）时这里是空的，那就只发请求
        let ids = conversation
            ? store.threadMessages(account: account, threadID: threadID).map(\.id)
            : (store.message(account: account, id: messageID) == nil ? [] : [messageID])
        guard !ids.isEmpty else { return [] }

        switch action {
        case .markRead:
            store.applyLabels(account: account, messageIDs: ids, add: [], remove: ["UNREAD"])
        case .archive:
            store.applyLabels(account: account, messageIDs: ids, add: [], remove: ["INBOX"])
        case .trash:
            store.applyTrash(account: account, messageIDs: ids)
        }
        return ids
    }

    /// 操作失败时回一条通知。用户按完按钮就走开了，不弹一下他不会知道没成。
    private func report(_ message: String) {
        guard NotificationPermission.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "邮件操作没能完成"
        content.body = message
        let request = UNNotificationRequest(identifier: "mail.action.failed.\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
