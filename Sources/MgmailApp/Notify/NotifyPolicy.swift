import Foundation

/// 通知策略：什么该弹、怎么弹。读的是设置窗口「通知」页里的那几项。
///
/// 与 `BackfillPolicy` 同一个路数——直接读 `UserDefaults`，不经过视图，
/// 因为判断发生在同步管线里（`MailStore`），那里拿不到 `@AppStorage`。
enum NotifyPolicy {
    /// 总开关。默认开。
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notifyEnabled) as? Bool ?? true
    }

    /// 只通知「主要」邮件：推广、社交、论坛三类不弹。默认开。
    ///
    /// 刻意**不**把 `CATEGORY_UPDATES` 算进屏蔽范围——订单确认、验证码、
    /// 服务告警都落在那一类里，那正是最需要立刻知道的邮件。
    static var mainCategoryOnly: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notifyMainCategoryOnly) as? Bool ?? true
    }

    /// 通知带提示音。默认开。
    static var sound: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notifySound) as? Bool ?? true
    }

    /// 在 Dock 图标上显示未读数。默认开。
    ///
    /// 这一项不依赖通知权限——`dockTile.badgeLabel` 是自家进程的事，
    /// 所以用户拒绝了通知授权时，角标仍然能用，是唯一的降级手段。
    static var dockBadge: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notifyDockBadge) as? Bool ?? true
    }

    /// 被静音的账号（邮箱地址集合）。不在集合里的账号一律通知。
    ///
    /// 存的是「静音名单」而不是「开启名单」，这样新登录的账号默认就有通知，
    /// 不需要用户再去设置里打开一遍。
    static var mutedAccounts: Set<String> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: SettingsKey.notifyMutedAccounts)
            return Set(raw ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: SettingsKey.notifyMutedAccounts)
        }
    }

    static func isMuted(_ account: String) -> Bool {
        mutedAccounts.contains(account)
    }

    static func setMuted(_ muted: Bool, account: String) {
        var set = mutedAccounts
        if muted { set.insert(account) } else { set.remove(account) }
        mutedAccounts = set
    }

    /// 这封新邮件值不值得打扰用户。
    ///
    /// `history.messagesAdded` 是**账户级**的，里面混着自己发出的信、刚存的草稿、
    /// 以及被判定为垃圾的邮件——它们都是「新增的邮件」，但都不该弹通知。
    /// 判断只能放在信头取回来之后：history 那一层只给 id，没有标签。
    static func shouldNotify(_ message: PooledMessage) -> Bool {
        let labels = Set(message.labelIds)
        // 必须是躺在收件箱里的未读邮件
        guard labels.contains("INBOX"), labels.contains("UNREAD") else { return false }
        // 自己发的、自己存的、被判垃圾的、已进废纸篓的，都不算「来信」
        guard labels.isDisjoint(with: ["SENT", "DRAFT", "SPAM", "TRASH"]) else { return false }
        if mainCategoryOnly, !labels.isDisjoint(with: mutedCategories) { return false }
        return true
    }

    private static let mutedCategories: Set<String> = [
        "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS",
    ]
}
