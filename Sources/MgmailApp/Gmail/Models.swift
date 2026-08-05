import Foundation

// MARK: - 标签

struct GmailLabel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String?               // "system" | "user"
    let messagesUnread: Int?
    let messagesTotal: Int?
    let color: LabelColor?

    var isSystem: Bool { type == "system" }
}

struct LabelColor: Codable, Hashable {
    let textColor: String?
    let backgroundColor: String?
}

// MARK: - 会话列表

struct ThreadListResponse: Decodable {
    let threads: [ThreadRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

struct ThreadRef: Decodable {
    let id: String
    let snippet: String?
    let historyId: String?
}

// MARK: - 邮件列表（不按会话显示时用）

struct MessageListResponse: Decodable {
    let messages: [MessageRef]?
    let nextPageToken: String?
    let resultSizeEstimate: Int?
}

struct MessageRef: Decodable {
    let id: String
    let threadId: String?
}

// MARK: - 会话 / 邮件详情

struct GmailThread: Decodable, Identifiable {
    let id: String
    let historyId: String?
    let messages: [GmailMessage]?
}

struct GmailMessage: Decodable, Identifiable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?       // 毫秒时间戳（字符串）
    let payload: MessagePart?

    var date: Date? {
        guard let ms = internalDate, let v = Double(ms) else { return nil }
        return Date(timeIntervalSince1970: v / 1000)
    }

    var isUnread: Bool { labelIds?.contains("UNREAD") ?? false }
    var isStarred: Bool { labelIds?.contains("STARRED") ?? false }
}

struct MessagePart: Decodable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    let body: PartBody?
    let parts: [MessagePart]?
}

struct Header: Decodable {
    let name: String
    let value: String
}

struct PartBody: Decodable {
    let attachmentId: String?
    let size: Int?
    let data: String?
}

// MARK: - 附件（解析后的视图模型）

struct Attachment: Codable, Identifiable, Hashable {
    var id: String { attachmentId }
    let messageID: String
    let attachmentId: String
    let filename: String
    let mimeType: String
    let size: Int

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - 增量同步（users.history）

struct GmailProfile: Decodable {
    let emailAddress: String?
    /// 账号当前的 historyId，作为下次增量同步的起点。
    let historyId: String?
}

struct HistoryListResponse: Decodable {
    let history: [HistoryRecord]?
    let nextPageToken: String?
    /// 本次拉取后的最新 historyId，存下来作为下次起点。
    let historyId: String?
}

/// 一条历史记录。同一条里可能同时有多种变化。
struct HistoryRecord: Decodable {
    let id: String
    let messagesAdded: [HistoryMessageChange]?
    let messagesDeleted: [HistoryMessageChange]?
    let labelsAdded: [HistoryLabelChange]?
    let labelsRemoved: [HistoryLabelChange]?
}

struct HistoryMessageChange: Decodable {
    let message: GmailMessage
}

struct HistoryLabelChange: Decodable {
    let message: GmailMessage
    /// 本次变动涉及的标签。
    let labelIds: [String]?
}

// MARK: - 标签修改请求体

struct ModifyRequest: Encodable {
    let addLabelIds: [String]?
    let removeLabelIds: [String]?
}
