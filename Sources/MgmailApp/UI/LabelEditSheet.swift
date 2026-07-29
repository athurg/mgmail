import SwiftUI

/// 标签编辑/新建面板：改名字 + 从 Gmail 允许的调色板选颜色。
struct LabelEditSheet: View {
    let target: LabelEditTarget
    @EnvironmentObject private var labelStore: LabelStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var color: LabelColor?
    @State private var busy = false
    @State private var errorText: String?

    private var isNew: Bool { target.label == nil }

    init(target: LabelEditTarget) {
        self.target = target
        _name = State(initialValue: target.label?.name ?? "")
        _color = State(initialValue: target.label?.color)
    }

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "新建标签" : "编辑标签").font(.title3).bold()

            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("标签名称（用 / 可建子标签）", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("颜色").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 8) {
                    // 无颜色（默认灰）
                    swatch(bg: nil, text: nil)
                    ForEach(GmailLabelPalette.colors, id: \.backgroundColor) { c in
                        swatch(bg: c.backgroundColor, text: c.textColor)
                    }
                }
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if !isNew {
                    Button("删除", role: .destructive) { deleteLabel() }.disabled(busy)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button(isNew ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func swatch(bg: String?, text: String?) -> some View {
        let fill = Color(hexString: bg) ?? Color.secondary.opacity(0.3)
        let selected = (color?.backgroundColor == bg) || (color == nil && bg == nil)
        return Circle()
            .fill(fill)
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hexString: text) ?? .primary)
                }
            }
            .overlay {
                if selected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                }
            }
            .contentShape(Circle())
            .onTapGesture {
                if let bg, let text {
                    color = LabelColor(textColor: text, backgroundColor: bg)
                } else {
                    color = nil
                }
            }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        busy = true
        errorText = nil
        Task {
            do {
                if let label = target.label {
                    try await labelStore.updateLabel(for: target.accountID, id: label.id, name: trimmed, color: color)
                } else {
                    try await labelStore.createLabel(for: target.accountID, name: trimmed, color: color)
                }
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                busy = false
            }
        }
    }

    private func deleteLabel() {
        guard let label = target.label else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await labelStore.deleteLabel(for: target.accountID, id: label.id)
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                busy = false
            }
        }
    }
}

/// Gmail 标签允许的调色板（背景色 + 匹配的文字色）。
enum GmailLabelPalette {
    static let colors: [LabelColor] = [
        .init(textColor: "#ffffff", backgroundColor: "#434343"),
        .init(textColor: "#ffffff", backgroundColor: "#666666"),
        .init(textColor: "#000000", backgroundColor: "#999999"),
        .init(textColor: "#000000", backgroundColor: "#cccccc"),
        .init(textColor: "#ffffff", backgroundColor: "#fb4c2f"),
        .init(textColor: "#ffffff", backgroundColor: "#e66550"),
        .init(textColor: "#ffffff", backgroundColor: "#cc3a21"),
        .init(textColor: "#ffffff", backgroundColor: "#ac2b16"),
        .init(textColor: "#ffffff", backgroundColor: "#ffad47"),
        .init(textColor: "#000000", backgroundColor: "#ffbc6b"),
        .init(textColor: "#ffffff", backgroundColor: "#eaa041"),
        .init(textColor: "#ffffff", backgroundColor: "#cf8933"),
        .init(textColor: "#000000", backgroundColor: "#fad165"),
        .init(textColor: "#000000", backgroundColor: "#fcda83"),
        .init(textColor: "#000000", backgroundColor: "#f2c960"),
        .init(textColor: "#ffffff", backgroundColor: "#d5ae49"),
        .init(textColor: "#ffffff", backgroundColor: "#16a766"),
        .init(textColor: "#ffffff", backgroundColor: "#149e60"),
        .init(textColor: "#ffffff", backgroundColor: "#0b804b"),
        .init(textColor: "#000000", backgroundColor: "#43d692"),
        .init(textColor: "#000000", backgroundColor: "#68dfa9"),
        .init(textColor: "#000000", backgroundColor: "#a0eac9"),
        .init(textColor: "#ffffff", backgroundColor: "#4a86e8"),
        .init(textColor: "#000000", backgroundColor: "#6d9eeb"),
        .init(textColor: "#ffffff", backgroundColor: "#3c78d8"),
        .init(textColor: "#ffffff", backgroundColor: "#285bac"),
        .init(textColor: "#ffffff", backgroundColor: "#a479e2"),
        .init(textColor: "#000000", backgroundColor: "#b694e8"),
        .init(textColor: "#ffffff", backgroundColor: "#8e63ce"),
        .init(textColor: "#ffffff", backgroundColor: "#653e9b"),
        .init(textColor: "#000000", backgroundColor: "#f691b3"),
        .init(textColor: "#000000", backgroundColor: "#f7a7c0"),
        .init(textColor: "#ffffff", backgroundColor: "#e07798"),
        .init(textColor: "#ffffff", backgroundColor: "#b65775"),
    ]
}
