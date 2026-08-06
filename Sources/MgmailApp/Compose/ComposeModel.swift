import SwiftUI
import AppKit

/// 一个撰写窗口的状态与动作。
@MainActor
final class ComposeModel: ObservableObject {
    /// Gmail 的 JSON 简单上传对整封报文的上限是 5MB。base64 会把附件撑大约 1/3，
    /// 所以按原始字节 3.5MB 拦，留出编码和头部的余量。
    static let attachmentLimit = 3_500_000

    @Published var mail: OutgoingMail
    @Published var isBusy = false
    @Published var errorText: String?
    /// 发送成功后置位，窗口据此自动关闭。
    @Published var didSend = false

    let kind: ComposeKind

    init(seed: ComposeStore.Seed) {
        self.kind = seed.kind
        self.mail = seed.mail
    }

    var canSend: Bool { mail.canSend && !isBusy }

    var isOverAttachmentLimit: Bool { mail.attachmentsSize > Self.attachmentLimit }

    var attachmentsSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(mail.attachmentsSize), countStyle: .file)
    }

    // MARK: - 附件

    func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                mail.attachments.append(try OutgoingAttachment(url: url))
            } catch {
                errorText = "读不了「\(url.lastPathComponent)」：\(error.localizedDescription)"
            }
        }
    }

    func remove(_ attachment: OutgoingAttachment) {
        mail.attachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - 发送 / 存草稿

    /// 发送。成功后置 `didSend`，窗口自己关掉。
    ///
    /// 发完顺手同步一次账号：Gmail 会把这封放进「已发送」，而本地池子是靠
    /// history 增量更新的，不主动催一下要等到下一次定时刷新才看得见。
    func send(labels: LabelStore, mail store: MailStore) async {
        guard canSend else { return }
        guard !isOverAttachmentLimit else {
            errorText = "附件太大（\(attachmentsSizeText)），上限 \(ByteCountFormatter.string(fromByteCount: Int64(Self.attachmentLimit), countStyle: .file))。"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let raw = MimeBuilder.build(mail)
            try await GmailAPI(account: mail.fromEmail).sendMessage(raw: raw, threadID: mail.threadID)
            didSend = true
            await MailRefresh.account(mail.fromEmail, labels: labels, mail: store, colors: false)
        } catch {
            errorText = message(for: error)
        }
    }

    /// 存草稿。同样发完催一次同步，草稿箱里才会立刻出现。
    func saveDraft(labels: LabelStore, mail store: MailStore) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let raw = MimeBuilder.build(mail)
            try await GmailAPI(account: mail.fromEmail).createDraft(raw: raw, threadID: mail.threadID)
            didSend = true
            await MailRefresh.account(mail.fromEmail, labels: labels, mail: store, colors: false)
        } catch {
            errorText = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
