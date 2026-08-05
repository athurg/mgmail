import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 应用内拖拽：一批会话/邮件（列表 → 侧栏标签）。
    static let mgmailThreads = UTType(exportedAs: "com.mgmail.threads")
    /// 应用内拖拽：一个标签（侧栏标签 → 列表）。
    static let mgmailLabel = UTType(exportedAs: "com.mgmail.label")
}

/// 应用内拖拽载荷。两个方向的拖拽源不同，但载荷格式（同一 UTType + JSON）是共用的：
///
/// - 邮件 → 标签：源是 `ThreadDragLayer`，自己编码后交给 NSDraggingSession。
///   列表行上不能挂任何 SwiftUI 拖拽 modifier，原因见该文件顶部。
/// - 标签 → 邮件：源是侧栏的 `.draggable`，走 `Transferable`。
///
/// 放置端一律手动解码 `NSItemProvider`（见 `decode(from:)`），两边因此互通。
protocol DragPayload: Codable, Transferable {
    static var contentType: UTType { get }
}

extension DragPayload {
    /// 从放下的 providers 里解出第一个本类型载荷。
    static func decode(from providers: [NSItemProvider]) async -> Self? {
        let type = contentType.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data, let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        }
        return nil
    }
}

/// 从列表拖出的会话/邮件。多选时一次带走整组（可能跨账号）。
struct ThreadDragPayload: DragPayload {
    let items: [SelectedThread]

    static var contentType: UTType { .mgmailThreads }

    /// 拖拽源用 `.draggable` 提供数据；放置端手动解码 provider（见 `decode(from:)`）。
    /// 两边都是同一个 UTType + JSON，互通。
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mgmailThreads)
    }

    /// 涉及的账号集合。打标签只在「全部属于标签所在账号」时才成立。
    var accountIDs: Set<String> { Set(items.map(\.accountID)) }
}

/// 从侧栏拖出的标签。
struct LabelDragPayload: DragPayload {
    let accountID: String
    let labelID: String
    let labelName: String

    static var contentType: UTType { .mgmailLabel }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mgmailLabel)
    }
}

/// 拖拽进行时，某个放置目标相对当前拖拽的状态。
enum DropAffinity {
    /// 没有相关拖拽在进行，正常显示。
    case neutral
    /// 可以接受，高亮。
    case enabled
    /// 明确不能接受（跨账号等），变灰。
    case disabled

    var dimmed: Bool { self == .disabled }
}
