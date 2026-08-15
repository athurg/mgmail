import Foundation

/// 一封邮件（或一串会话）在「收件箱 → 归档 → 废纸篓」这条线上的位置。
///
/// 三态互斥，各自只有一组说得通的动作：
/// - 收件箱：可以归档、可以删除；
/// - 归档（不在收件箱，也没被删）：可以移回收件箱、可以删除；
/// - 废纸篓：只剩移回收件箱一条路——再删一次就是永久删除，那不是这个应用做的事。
///
/// 换句话说，归档和删除都不再是单向的：邮件到了哪一态，按钮就换成那一态还剩下的动作，
/// 和已读/未读、星标一样能来回走。
///
/// 刻意只依赖标签集合、不引用任何界面或存储类型，理由同 `MailboxQuery`：
/// 这样它能被 `Scripts/check_mailbox.sh` 单独编出来自检。
enum MailPlacement: Hashable {
    case inbox
    case archived
    case trashed

    /// 由标签集合判断。
    ///
    /// INBOX 优先于 TRASH：会话模式下这组标签是整串邮件的并集，一串里只要还有一封在
    /// 收件箱，这一行就还算在收件箱里——列表的归属判断也是按「有没有哪一封属于这个邮箱」
    /// 算的（见 `ThreadListModel.recompute`），两边得对上。
    init(labels: Set<String>) {
        if labels.contains("INBOX") {
            self = .inbox
        } else if labels.contains("TRASH") {
            self = .trashed
        } else {
            self = .archived
        }
    }

    init(labels: [String]) {
        self.init(labels: Set(labels))
    }

    var canArchive: Bool { self == .inbox }
    var canMoveToInbox: Bool { self != .inbox }
    var canTrash: Bool { self != .trashed }

    // MARK: - 「归档 / 移回收件箱」那一个按钮的两副面孔

    var moveTitle: String { canArchive ? "归档" : "移回收件箱" }

    var moveIcon: String { canArchive ? "archivebox" : "tray.and.arrow.down" }

    var moveHelp: String { canArchive ? "归档（移出收件箱）" : "移回收件箱" }

    // MARK: - 放回收件箱要动的标签

    /// 加 INBOX，并摘掉 SPAM——垃圾邮件也是「不在收件箱」的一种，放回去就该一并解除。
    ///
    /// TRASH 不在这里：从废纸篓恢复得走 `untrash` 接口，标签改不动它。
    static let inboxAdd = ["INBOX"]
    static let inboxRemove = ["SPAM"]
}
