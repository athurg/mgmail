import Foundation

/// 一次增量同步的结果。三类变化都记 `邮件 id → 所属会话 id`，
/// 因为列表在「按会话」和「按单封」两种模式下用的行 id 不同。
struct SyncOutcome {
    /// 新到达的邮件。
    var added: [String: String] = [:]
    /// 被彻底删除的邮件。
    var removed: [String: String] = [:]
    /// 标签有变动的邮件（读/未读、星标、归档、打标签都算）。
    var changed: [String: String] = [:]
    /// 起点太旧，增量拿不到了，调用方需要退回全量刷新。
    var needsFullReload = false

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && !needsFullReload
    }
}

/// 基于 `users.history` 的增量同步。
///
/// 之前每次「刷新」都是把当前页整个重拉一遍（list + 一页的 get）。
/// history.list 只回自上次同步以来的变化，通常是空的——一次请求、几百字节，
/// 因此可以放心地定时跑。
enum MailSync {
    /// 拉取某账号自上次位点以来的变化。
    ///
    /// 首次调用时本地没有位点，只记录当前 historyId 并返回空结果：
    /// 此时"变化"的概念还不成立，全量加载会负责铺满首屏。
    static func incremental(account: String) async -> SyncOutcome {
        let api = GmailAPI(account: account)

        guard let start = await MailCache.shared.historyID(account: account) else {
            await captureStartPoint(account: account, api: api)
            return SyncOutcome()
        }

        var outcome = SyncOutcome()
        var pageToken: String?
        var latestHistoryID: String?

        repeat {
            do {
                let page = try await api.listHistory(startHistoryId: start, pageToken: pageToken)
                apply(page.history ?? [], to: &outcome)
                latestHistoryID = page.historyId ?? latestHistoryID
                pageToken = page.nextPageToken
            } catch let GmailError.http(code, _) where code == 404 {
                // 位点太旧（Gmail 只保留约一周）：丢弃它，重新取一个，并让调用方全量刷新
                outcome.needsFullReload = true
                await captureStartPoint(account: account, api: api)
                return outcome
            } catch {
                // 网络抖动等：这次放弃，位点不动，下次接着从原点拉
                return SyncOutcome()
            }
        } while pageToken != nil

        if let latestHistoryID {
            await MailCache.shared.saveHistoryID(latestHistoryID, account: account)
        }
        return outcome
    }

    /// 记录当前 historyId 作为后续增量的起点。
    private static func captureStartPoint(account: String, api: GmailAPI) async {
        guard let historyID = try? await api.getProfile().historyId else { return }
        await MailCache.shared.saveHistoryID(historyID, account: account)
    }

    /// 把一页历史记录归并进结果。
    ///
    /// 同一封邮件可能在一页里出现多次（先到达、再被打标签），归并顺序因此重要：
    /// 删除优先级最高，新增次之，标签变动最低。
    private static func apply(_ records: [HistoryRecord], to outcome: inout SyncOutcome) {
        for record in records {
            for change in record.messagesAdded ?? [] {
                let message = change.message
                outcome.added[message.id] = message.threadId ?? message.id
                outcome.removed.removeValue(forKey: message.id)
            }
            for change in record.messagesDeleted ?? [] {
                let message = change.message
                outcome.removed[message.id] = message.threadId ?? message.id
                outcome.added.removeValue(forKey: message.id)
                outcome.changed.removeValue(forKey: message.id)
            }
            for change in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                let message = change.message
                let id = message.id
                guard outcome.removed[id] == nil, outcome.added[id] == nil else { continue }
                outcome.changed[id] = message.threadId ?? id
            }
        }
    }
}
