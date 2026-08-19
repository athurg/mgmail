import Foundation

/// 定时同步时顺手把新邮件的正文也取回来，用户点开就是本地缓存，不必等一次网络往返。
///
/// 只跟着增量同步带回来的新邮件走，和新邮件通知同一条线：首次全量那几百封走的是
/// 回溯拉取，不经过这里——否则加个账号就先下几百封正文，用户还一封都没打算看。
///
/// 取不到不重要，也不报错：预取只是提前量，缺了最多是打开时慢一点，
/// 那正是没有预取时的常态。所以它排在同步流程的最后，前面的位点、欠账、对账
/// 一件都不该为它让路。
enum BodyPrefetch {
    /// 一轮同步最多预取几封。
    ///
    /// 正文比信头贵得多——一封带内联图的能有几 MB，而信头一页 100 封也才几十 KB。
    /// 合盖一夜再打开可能一次涌进上百封，那种时候取回最新的这些就够了，
    /// 再往下翻的用户自然会等那一次请求。
    static let perSyncLimit = 10

    /// 预取这批新邮件的正文。
    static func run(_ messages: [PooledMessage], account: String) async {
        guard !messages.isEmpty else { return }
        // 按会话显示时，用户点开一行拿到的是整串，缓存的键也是会话 id——
        // 预取要跟界面用同一把键，否则存下来的那份谁也找不到
        let conversation = UserDefaults.standard.bool(forKey: SettingsKey.conversationView)

        var visited: Set<String> = []
        var fetched = 0
        // 最新的先取：截断发生时，留下的该是用户最可能先点开的那几封
        for message in messages.sorted(by: { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }) {
            guard fetched < perSyncLimit else { break }
            guard isWorthFetching(message) else { continue }

            let key = conversation ? message.threadId : message.id
            guard visited.insert(key).inserted else { continue } // 同一会话里的多封只值一次请求
            // 单封的正文不会变，缓存里有就不必再取。会话则要重取：新来的这封
            // 还不在那份缓存里，不覆盖的话点开看到的是少了一封的旧会话。
            if !conversation, await MailCache.shared.hasThread(account: account, threadID: key,
                                                               conversation: false) { continue }

            fetched += 1
            do {
                _ = try await MessageBodyLoader.load(account: account, threadID: key,
                                                     conversation: conversation)
            } catch {
                // 一封没取回来，多半是网络或配额出了问题，接着取只是让这一轮同步拖更久
                // ——每次失败前还各有几轮退避重试。剩下的等下一轮，或者等用户自己点开。
                return
            }
        }
    }

    /// 值不值得提前取：草稿点开进的是撰写窗口，垃圾邮件和废纸篓里的多半不会被打开。
    private static func isWorthFetching(_ message: PooledMessage) -> Bool {
        Set(message.labelIds).isDisjoint(with: ["TRASH", "SPAM", "DRAFT"])
    }
}
