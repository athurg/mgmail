import SwiftUI

/// 给当前会话加/去标签，并支持新建标签。
struct LabelEditorView: View {
    let account: String
    @ObservedObject var detail: MessageDetailModel
    @EnvironmentObject private var labelStore: LabelStore
    var onChange: () -> Void = {}

    @State private var newLabelName = ""
    @State private var busy = false
    @State private var errorText: String?

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
        }
        .padding(12)
        .frame(width: 260)
        .task { await labelStore.load(for: account) }
    }

    private func labelRow(_ label: GmailLabel) -> some View {
        let isOn = detail.threadLabelIds.contains(label.id)
        return Button {
            toggle(label, isOn: isOn)
        } label: {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Image(systemName: "tag.fill")
                    .font(.caption2)
                    .foregroundStyle(label.uiColor ?? Color.secondary.opacity(0.5))
                Text(label.name).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .disabled(busy)
    }

    private func toggle(_ label: GmailLabel, isOn: Bool) {
        busy = true
        errorText = nil
        Task {
            do {
                try await detail.modify(add: isOn ? [] : [label.id], remove: isOn ? [label.id] : [])
                onChange()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
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
                newLabelName = ""
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }
}
