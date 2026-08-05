import Foundation

/// 一次请求「在做什么」的人话说明。
///
/// 绝大多数情况由 URL 自己推断出来，调用方不用埋点——这样新加的接口
/// 也会自动出现在日志里，不会漏。只有批量请求需要调用方补一句，
/// 因为它的 URL 是同一个 `/batch/gmail/v1`，看不出内容。
struct ActivityDescriptor: Sendable {
    let kind: ActivityKind
    let title: String

    init(kind: ActivityKind, title: String) {
        self.kind = kind
        self.title = title
    }

    // MARK: - 从 URL 推断

    static func infer(url: URL, method: String) -> ActivityDescriptor {
        let host = url.host ?? ""
        if host.contains("oauth2") || host.contains("accounts.google") {
            return .init(kind: .auth, title: "获取访问令牌")
        }
        if host.contains("openidconnect") || url.path.contains("userinfo") {
            return .init(kind: .profile, title: "读取账户资料")
        }

        var path = url.path
        let prefix = "/gmail/v1/users/me"
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        let segments = path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        switch segments.first {
        case "labels":
            if segments.count == 1 {
                return .init(kind: .label, title: method == "POST" ? "新建标签" : "获取标签列表")
            }
            switch method {
            case "PATCH", "PUT": return .init(kind: .label, title: "修改标签")
            case "DELETE": return .init(kind: .label, title: "删除标签")
            default: return .init(kind: .label, title: "读取标签详情")
            }

        case "threads", "messages":
            let isThread = segments.first == "threads"
            if segments.count == 1 {
                let scope = value("labelIds").map { "（\(mailboxName($0))）" } ?? ""
                return .init(kind: .list, title: (isThread ? "获取会话列表" : "获取邮件列表") + scope)
            }
            if segments.count >= 3 {
                switch segments[2] {
                case "attachments": return .init(kind: .attachment, title: "下载附件")
                case "modify": return .init(kind: .modify, title: "更新邮件标记")
                case "trash": return .init(kind: .modify, title: "移到废纸篓")
                case "untrash": return .init(kind: .modify, title: "从废纸篓恢复")
                default: break
                }
            }
            if value("format") == "metadata" {
                return .init(kind: .message, title: isThread ? "读取会话信息" : "读取邮件信息")
            }
            return .init(kind: .message, title: isThread ? "读取会话内容" : "读取邮件内容")

        case "history":
            return .init(kind: .sync, title: "检查新邮件")

        case "profile":
            return .init(kind: .sync, title: "读取邮箱状态")

        default:
            return .init(kind: .other, title: "\(method) \(path.isEmpty ? url.absoluteString : path)")
        }
    }

    /// 批量请求：拿第一条子请求推断在做什么，再标出条数。
    static func batch(_ items: [BatchItem]) -> ActivityDescriptor {
        guard let first = items.first else {
            return .init(kind: .other, title: "批量请求")
        }
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
        comps.path += first.path
        if !first.query.isEmpty { comps.queryItems = first.query }
        guard let url = comps.url else {
            return .init(kind: .other, title: "批量请求（\(items.count) 项）")
        }
        let base = infer(url: url, method: "GET")
        return .init(kind: base.kind, title: "\(base.title) ×\(items.count)")
    }

    /// 系统标签在日志里也给中文名，否则一眼看不出是哪个邮箱。
    private static func mailboxName(_ labelID: String) -> String {
        if let box = StandardMailbox.all.first(where: { $0.id == labelID }) { return box.name }
        if let category = MailCategory.all.first(where: { $0.id == labelID }) { return category.name }
        return labelID
    }
}
