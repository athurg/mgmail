import SwiftUI

/// 给当前会话加/去标签，并支持新建标签。
/// 勾选只改本地状态，点「应用」才发一次网络请求（避免每次点击都打一趟）。
struct LabelEditorView: View {
    let account: String
    @ObservedObject var detail: MessageDetailModel
    @EnvironmentObject private var labelStore: LabelStore
    /// 关闭 popover。由宿主视图控制，比在 popover 里用 `dismiss` 可靠。
    var onClose: () -> Void = {}

    /// 打开面板时该会话已有的用户标签。
    @State private var original: Set<String> = []
    /// 当前勾选状态（本地，未提交）。
    @State private var selected: Set<String> = []
    @State private var newLabelName = ""
    @State private var busy = false
    @State private var errorText: String?

    private var added: [String] { Array(selected.subtracting(original)) }
    private var removed: [String] { Array(original.subtracting(selected)) }
    private var changeCount: Int { added.count + removed.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("标签").font(.headline)

            let labels = labelStore.userLabels(for: account)
            if labels.isEmpty {
                Text("暂无自定义标签").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(labels) { label in
                            labelRow(label)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()

            HStack {
                TextField("新建标签", text: $newLabelName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createLabel() }
                Button("创建") { createLabel() }
                    .disabled(newLabelName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                if changeCount > 0 {
                    Text("\(changeCount) 项待应用").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("取消") { onClose() }
                Button("应用") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changeCount == 0 || busy)
            }
        }
        .padding(12)
        .frame(width: 260)
        .task {
            syncFromThread()
            await labelStore.load(for: account)
            // 刷新后可能多出标签；仅在用户尚未改动时重新对齐，避免覆盖已勾选内容
            if selected == original { syncFromThread() }
        }
    }

    /// 用会话当前的标签重置勾选状态。
    private func syncFromThread() {
        let ids = Set(labelStore.userLabels(for: account).map(\.id))
        original = ids.intersection(detail.threadLabelIds)
        selected = original
    }

    private func labelRow(_ label: GmailLabel) -> some View {
        let isOn = selected.contains(label.id)
        return Button {
            if isOn { selected.remove(label.id) } else { selected.insert(label.id) }
        } label: {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Image(systemName: "tag.fill")
                    .font(.caption2)
                    .foregroundStyle(label.uiColor ?? Color.secondary.opacity(0.5))
                Text(label.name).lineLimit(1)
                Spacer()
                // 与打开时相比有变化的项，右侧给个提示
                if original.contains(label.id) != isOn {
                    Image(systemName: isOn ? "plus.circle" : "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(isOn ? Color.green : Color.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .disabled(busy)
    }

    /// 一次性提交所有勾选变更。
    private func apply() {
        guard changeCount > 0 else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await detail.modify(add: added, remove: removed)
                busy = false
                onClose()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                busy = false
            }
        }
    }

    private func createLabel() {
        let name = newLabelName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await labelStore.createLabel(for: account, name: name)
                // 新建的标签默认勾上，随后一起应用
                if let created = labelStore.userLabels(for: account).first(where: { $0.name == name }) {
                    selected.insert(created.id)
                }
                newLabelName = ""
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }
}
