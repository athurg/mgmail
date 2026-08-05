import Foundation

/// 跨视图共用的邮件操作（列表、侧栏拖放、详情栏都会用到）。
enum MailActions {
    /// 给一批会话/邮件增删标签，并发执行。返回首个错误描述（全部成功为 nil）。
    static func modify(_ items: [SelectedThread], add: [String] = [], remove: [String] = [],
                       conversation: Bool) async -> String? {
        guard !items.isEmpty else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            for item in items {
                group.addTask {
                    let api = GmailAPI(account: item.accountID)
                    do {
                        if conversation {
                            try await api.modifyThread(id: item.threadID, add: add, remove: remove)
                        } else {
                            try await api.modifyMessage(id: item.threadID, add: add, remove: remove)
                        }
                        return nil
                    } catch {
                        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
            var firstError: String?
            for await failure in group where firstError == nil {
                firstError = failure
            }
            return firstError
        }
    }
}
