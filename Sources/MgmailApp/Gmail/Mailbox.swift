import Foundation

/// 标准邮箱定义（映射到 Gmail 系统标签）。
struct StandardMailbox: Identifiable, Hashable {
    let id: String                 // 选择用的标识
    let name: String
    let systemImage: String
    /// 传给 Gmail API 的 labelId；nil 表示不按标签过滤（「所有邮件」）。
    var apiLabelID: String?
    /// 是否需要包含 SPAM/TRASH（按这两个标签过滤时必须为 true）。
    var includeSpamTrash: Bool = false

    /// 「所有邮件」的特殊标识。
    static let allMailID = "ALL_MAIL"

    /// 账号分组里列出的全部邮箱。
    static let all: [StandardMailbox] = [
        .init(id: "INBOX", name: "收件箱", systemImage: "tray", apiLabelID: "INBOX"),
        .init(id: "STARRED", name: "已加星标", systemImage: "star", apiLabelID: "STARRED"),
        .init(id: "SENT", name: "已发送", systemImage: "paperplane", apiLabelID: "SENT"),
        .init(id: "DRAFT", name: "草稿", systemImage: "doc", apiLabelID: "DRAFT"),
        .init(id: allMailID, name: "所有邮件", systemImage: "tray.full", apiLabelID: nil),
        .init(id: "SPAM", name: "垃圾邮件", systemImage: "xmark.bin", apiLabelID: "SPAM", includeSpamTrash: true),
        .init(id: "TRASH", name: "废纸篓", systemImage: "trash", apiLabelID: "TRASH", includeSpamTrash: true),
    ]

    /// 侧栏顶部「智能邮箱」里跨账号聚合的那几个。
    ///
    /// 只放日常真正会跨账号一起看的两个。已发送/草稿/垃圾邮件/废纸篓都是
    /// 「针对某个账号」才有意义的，去各账号自己的分组里看。
    static let smart: [StandardMailbox] = all.filter { $0.id == "INBOX" || $0.id == "STARRED" }
}

/// Gmail 的收件箱分类标签（CATEGORY_*）。系统标签的 name 就是英文 id，这里给中文名与图标。
struct MailCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let systemImage: String

    static let all: [MailCategory] = [
        .init(id: "CATEGORY_PERSONAL", name: "主要", systemImage: "person"),
        .init(id: "CATEGORY_SOCIAL", name: "社交", systemImage: "person.2"),
        .init(id: "CATEGORY_PROMOTIONS", name: "推广", systemImage: "megaphone"),
        .init(id: "CATEGORY_UPDATES", name: "更新", systemImage: "bell.badge"),
        .init(id: "CATEGORY_FORUMS", name: "论坛", systemImage: "bubble.left.and.bubble.right"),
    ]
}

/// 把选中的邮箱标识解析成「拉取时传什么参数」与「本地怎么判断一封邮件属于它」。
///
/// 后者是重构后的关键：邮件都在账户级的池子里，各个邮箱视图不过是对同一份数据的不同过滤。
/// 刻意不引用 `PooledMessage`：判断只看标签集合，这样这段逻辑不依赖任何
/// 界面或存储类型，可以被 `Scripts/check_mailbox.sh` 单独编出来跑。
/// 对邮件本身的重载在 `MailStore` 那边。
struct MailboxQuery {
    let apiLabelID: String?
    let includeSpamTrash: Bool
    /// 仅凭标签集合判断是否属于该邮箱。
    let labelsBelong: ([String]) -> Bool

    static func resolve(labelID: String) -> MailboxQuery {
        if let box = StandardMailbox.all.first(where: { $0.id == labelID }) {
            if box.id == StandardMailbox.allMailID {
                // 所有邮件：不按标签过滤，只把垃圾/废纸篓摘出去
                return MailboxQuery(apiLabelID: nil, includeSpamTrash: false) { labels in
                    !isDiscarded(labels)
                }
            }
            let apiID = box.apiLabelID
            return MailboxQuery(apiLabelID: apiID, includeSpamTrash: box.includeSpamTrash) { labels in
                guard let apiID else { return true }
                guard labels.contains(apiID) else { return false }
                // 废纸篓/垃圾邮件这两个邮箱自己就是终点，不再自我排除
                return box.includeSpamTrash || !isDiscarded(labels)
            }
        }
        // 用户自定义标签，以及收件箱分类（CATEGORY_*）
        return MailboxQuery(apiLabelID: labelID, includeSpamTrash: false) { labels in
            labels.contains(labelID) && !isDiscarded(labels)
        }
    }

    /// 这封信是不是已经被丢掉了。
    ///
    /// 删除和标记垃圾在 Gmail 里都只是加个标签，原有的 SENT、STARRED、用户标签
    /// 一个不少地留着。不排除的话，删掉的已发送邮件仍然挂在「已发送」里，
    /// 星标过的垃圾邮件仍然挂在「已加星标」里——和 Gmail 网页版对不上。
    private static func isDiscarded(_ labels: [String]) -> Bool {
        labels.contains("TRASH") || labels.contains("SPAM")
    }

    /// 除垃圾邮件与废纸篓外，其余邮箱的邮件都在账户级列表的返回范围内。
    /// 这两个必须显式点进去才拉——Gmail 默认不返回它们。
    static func needsExplicitFetch(labelID: String) -> Bool {
        labelID == "SPAM" || labelID == "TRASH"
    }
}
