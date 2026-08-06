import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 应用内拖拽：一个标签（侧栏标签 → 列表）。
    static let mgmailLabel = UTType(exportedAs: "com.mgmail.label")
}

/// 应用内拖拽载荷。源是侧栏标签的 `.draggable`（走 `Transferable`），
/// 放置端是列表行，手动解码 `NSItemProvider`（见 `decode(from:)`），两边靠同一个
/// UTType + JSON 互通。
///
/// 反方向（把邮件从列表拖到标签上）已经去掉了：那需要在列表上截获 mouseDown 才能实现，
/// 而判定「这一下是拖拽还是点击」只能靠位移阈值，越过阈值的点击会被整个吞掉、选不中邮件。
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
