import Foundation

/// 一封邮件这一轮里被加了哪些标签、去了哪些标签。
struct LabelDelta {
    var add: Set<String> = []
    var remove: Set<String> = []
}

/// 一次增量同步的结果。
struct SyncOutcome {
    /// 新到达的邮件（id → 所属会话 id）。只有 id，信头要另外取。
    var added: [String: String] = [:]
    /// 被彻底删除的邮件 id（移进废纸篓不算，那只是标签变动）。
    var removed: Set<String> = []
    /// 标签有变动的邮件。**变动内容 history 已经给全了**，本地按增删应用即可，
    /// 不需要再逐封 get 去问「现在的标签是什么」。
    var labelChanges: [String: LabelDelta] = [:]
    /// 起点太旧，增量拿不到了，调用方需要退回全量重建。
    var needsFullReload = false
    /// 本轮拉到的最新位点。**故意不在这里存盘**——见 `MailSync.incremental` 的说明。
    var latestHistoryID: String?

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && labelChanges.isEmpty && !needsFullReload
    }
}

/// 基于 `users.history` 的增量同步。
///
/// history.list 只回自上次同步以来的变化，通常是空的——一次请求、几百字节，
/// 而且它是**账户级**的：一个请求就覆盖了这个账号的所有邮箱。
enum MailSync {
    /// 拉取某账号自上次位点以来的变化。
    ///
    /// 新位点只放进结果里带回去，**不在这里存盘**：history 只给了新邮件的 id，
    /// 信头还得再取一趟，那一趟失败了这批邮件就没进池子。位点要是已经推过去了，
    /// 下次增量便不会再提这些邮件，而回溯那条线一旦走到头也不会回头补——
    /// 一次网络抖动就够让几封信永远消失。所以存盘的时机交给调用方，
    /// 由它在信头确实拿到之后再落。
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
                // 位点太旧（Gmail 只保留约一周）：丢弃它，重新取一个，并让调用方重建
                outcome.needsFullReload = true
                await captureStartPoint(account: account, api: api)
                return outcome
            } catch {
                // 网络抖动等：这次放弃，位点不动，下次接着从原点拉
                return SyncOutcome()
            }
        } while pageToken != nil

        // 新到的邮件会连它的信头一起取回来，那份是最新的，标签增删就不必再算了
        for id in outcome.added.keys {
            outcome.labelChanges.removeValue(forKey: id)
        }
        outcome.latestHistoryID = latestHistoryID
        return outcome
    }

    /// 把位点推到本轮拉到的位置。调用方确认这一轮的邮件都已落地后才调。
    static func commit(_ outcome: SyncOutcome, account: String) async {
        guard let id = outcome.latestHistoryID else { return }
        await MailCache.shared.saveHistoryID(id, account: account)
    }

    /// 还没有位点时记一个，作为后续增量的起点。
    static func captureStartPointIfNeeded(account: String) async {
        guard await MailCache.shared.historyID(account: account) == nil else { return }
        await captureStartPoint(account: account, api: GmailAPI(account: account))
    }

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
                outcome.removed.remove(message.id)
            }
            for change in record.messagesDeleted ?? [] {
                let message = change.message
                outcome.removed.insert(message.id)
                outcome.added.removeValue(forKey: message.id)
                outcome.labelChanges.removeValue(forKey: message.id)
            }
            for change in record.labelsAdded ?? [] {
                merge(change, into: &outcome, added: true)
            }
            for change in record.labelsRemoved ?? [] {
                merge(change, into: &outcome, added: false)
            }
        }
    }

    /// 同一封邮件先后被加又被去同一个标签时，以后来的为准。
    private static func merge(_ change: HistoryLabelChange, into outcome: inout SyncOutcome, added: Bool) {
        let id = change.message.id
        guard !outcome.removed.contains(id), let labels = change.labelIds, !labels.isEmpty else { return }
        var delta = outcome.labelChanges[id] ?? LabelDelta()
        if added {
            delta.add.formUnion(labels)
            delta.remove.subtract(labels)
        } else {
            delta.remove.formUnion(labels)
            delta.add.subtract(labels)
        }
        outcome.labelChanges[id] = delta
    }
}
