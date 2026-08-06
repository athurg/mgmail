import Foundation
import UniformTypeIdentifiers

/// 一封待发出的邮件。
///
/// 收件人这类字段存的是用户原样输入的串（可能是 `张三 <a@b.com>, c@d.com`），
/// 拆分和编码留到拼报文时做——编辑期间不该因为少打一个字符就把内容判成非法。
struct OutgoingMail {
    var fromName: String
    var fromEmail: String
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    var attachments: [OutgoingAttachment] = []

    /// 回复时填原邮件的 Message-ID，让对方的客户端能把这封串进原会话。
    var inReplyTo: String?
    /// 原会话已有的 Message-ID 链，回复时接在后面。
    var references: [String] = []
    /// Gmail 自己的会话 id。发送时带上，这封才会落在原会话里而不是另起一串。
    var threadID: String?

    /// 转发时要一并带走的原邮件附件。
    ///
    /// 只存引用不存内容：附件动辄几 MB，开窗那一刻同步拉下来会让窗口卡着不出来。
    /// 窗口起来之后由 `ComposeModel` 后台取回，取一个填一个。
    var pendingAttachments: [Attachment] = []
    /// `pendingAttachments` 从哪个账号取。转发的原件未必属于当前发件账号。
    var attachmentSourceAccount: String?

    /// 至少得有一个收件人才能发。
    var canSend: Bool {
        !MimeBuilder.splitAddresses(to).isEmpty
            || !MimeBuilder.splitAddresses(cc).isEmpty
            || !MimeBuilder.splitAddresses(bcc).isEmpty
    }

    var attachmentsSize: Int { attachments.reduce(0) { $0 + $1.data.count } }
}

/// 待发送的附件（内容已经读进内存——要发出去总得读，边发边读省不了什么）。
struct OutgoingAttachment: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        self.filename = url.lastPathComponent
        self.data = data
        self.mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}

/// 撰写窗口是哪种来路。决定标题栏文案，以及正文里预填什么。
enum ComposeKind {
    case new
    case reply(all: Bool)
    case forward

    var windowTitle: String {
        switch self {
        case .new: return "新邮件"
        case .reply(let all): return all ? "全部回复" : "回复"
        case .forward: return "转发"
        }
    }
}
