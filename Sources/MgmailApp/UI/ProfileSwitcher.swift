import SwiftUI

/// 侧栏顶部的分组切换器：一排胶囊标签，「全部」固定在最左且不可删。
/// 点击切换当前分组；右键单个标签可改名/换色/删除；最右 + 号新建分组。
///
/// 标签排不下时往下折行，不做横向滚动：滚动会把标签裁在卡片边上，看着像少了半个；
/// 折行则始终全部可见。
struct ProfileSwitcher: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKey.settingsTab) private var settingsTab = SettingsTab.accounts.rawValue
    /// 正在重命名的分组 id（nil 表示无）。
    @State private var renaming: String?
    @State private var renameText = ""
    /// 正在被拖动的分组 id（用于降低源标签透明度）。
    @State private var draggingID: String?
    /// 当前拖放悬停的目标分组 id（用于画插入指示）。
    @State private var dropTargetID: String?

    var body: some View {
        WrappingRow(spacing: 6, lineSpacing: 6) {
            allChip
            ForEach(appState.profiles) { profile in
                profileChip(profile)
            }
            addButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 兜底：拖到标签之间的空白处则移到末尾；同时保证拖动结束后状态复位。
        .dropDestination(for: String.self) { items, _ in
            defer { draggingID = nil; dropTargetID = nil }
            guard let dragged = items.first else { return false }
            appState.moveProfileToEnd(dragged)
            return true
        }
        .alert("重命名分组", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("分组名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let id = renaming { appState.renameProfile(id, to: renameText) }
                renaming = nil
            }
        }
    }

    /// 内置「所有分组」：显示全部账号（含未分组），恒在最左，不可拖动/删除。
    private var allChip: some View {
        chip(title: "所有分组", color: .secondary, isSelected: appState.currentProfileID == nil) {
            appState.setCurrentProfile(nil)
        }
        // 拖到「所有分组」上 → 把该分组移到最前（否则会落到外层兜底逻辑被移到末尾）。
        .dropDestination(for: String.self) { items, _ in
            defer { draggingID = nil; dropTargetID = nil }
            guard let dragged = items.first,
                  let first = appState.profiles.first, first.id != dragged else { return false }
            appState.moveProfile(dragged, relativeTo: first.id, after: false)
            return true
        }
        .contextMenu {
            Button("管理分组…") { openProfileSettings() }
        }
    }

    private func profileChip(_ profile: Profile) -> some View {
        let isSelected = appState.currentProfileID == profile.id
        return chip(title: profile.name, color: profile.color, isSelected: isSelected) {
            // 再点一次已选中的分组 → 取消过滤，回到「全部账号」。
            appState.setCurrentProfile(isSelected ? nil : profile.id)
        }
        .opacity(draggingID == profile.id ? 0.4 : 1)
        .overlay(alignment: .leading) {
            // 悬停时在目标一侧画一条插入指示线
            if dropTargetID == profile.id, let dragging = draggingID, dragging != profile.id {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5)
                    .offset(x: insertsAfter(dragged: dragging, target: profile.id) ? 0 : -4)
                    .frame(maxWidth: .infinity, alignment: insertsAfter(dragged: dragging, target: profile.id) ? .trailing : .leading)
            }
        }
        .draggable(profile.id) {
            // 拖动预览
            Text(profile.name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(profile.color.opacity(0.9)))
                .foregroundStyle(.white)
                .onAppear { draggingID = profile.id }
        }
        .dropDestination(for: String.self) { items, _ in
            defer { draggingID = nil; dropTargetID = nil }
            guard let dragged = items.first, dragged != profile.id else { return false }
            appState.moveProfile(dragged, relativeTo: profile.id,
                                 after: insertsAfter(dragged: dragged, target: profile.id))
            return true
        } isTargeted: { targeted in
            dropTargetID = targeted ? profile.id : (dropTargetID == profile.id ? nil : dropTargetID)
        }
        .contextMenu {
            Button("重命名…") {
                renameText = profile.name
                renaming = profile.id
            }
            Menu("颜色") {
                ForEach(Profile.palette.indices, id: \.self) { i in
                    Button {
                        appState.setProfileColor(profile.id, colorIndex: i)
                    } label: {
                        Label(colorName(i), systemImage: i == profile.colorIndex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Divider()
            Button("管理分组…") { openProfileSettings() }
            Divider()
            Button("删除分组", role: .destructive) { appState.deleteProfile(profile.id) }
        }
    }

    /// 一个胶囊标签。选中态用分组色填充，未选中为描边。
    private func chip(title: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected ? color.opacity(0.9) : Color.clear)
            )
            .overlay(
                // 未选中时用分组色描边，颜色设置在两种状态下都能看出来
                Capsule().stroke(isSelected ? Color.clear : color.opacity(0.55), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button {
            let profile = appState.addProfile(name: "新分组")
            renameText = profile.name
            renaming = profile.id
        } label: {
            Image(systemName: "plus")
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("新建分组")
        .contextMenu {
            Button("管理分组…") { openProfileSettings() }
        }
    }

    /// 打开设置窗口并切到「分组」页。
    private func openProfileSettings() {
        settingsTab = SettingsTab.profiles.rawValue
        openSettings()
    }

    /// 从左往右拖时落到目标右侧，从右往左拖时落到左侧——符合直觉，且不必算落点坐标。
    private func insertsAfter(dragged: String, target: String) -> Bool {
        guard let from = appState.profiles.firstIndex(where: { $0.id == dragged }),
              let to = appState.profiles.firstIndex(where: { $0.id == target }) else { return false }
        return from < to
    }

    private func colorName(_ index: Int) -> String {
        ["蓝", "绿", "橙红", "紫", "粉", "琥珀", "灰"][index % 7]
    }
}

/// 从左往右排、排满就折到下一行的布局；同一行里的东西按竖向居中对齐。
private struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for item in row.items {
                let y = row.y + (row.height - item.size.height) / 2
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + y),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row(y: 0)]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            // 这一行已经有东西且塞不下了，就折行；空行上的第一个不折，再宽也得放，否则会无限折下去
            if x > 0, x + size.width > width {
                rows.append(Row(y: rows[rows.count - 1].y + rows[rows.count - 1].height + lineSpacing))
                x = 0
            }
            rows[rows.count - 1].items.append((index, x, size))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width
            rows[rows.count - 1].width = x
            x += spacing
        }
        return rows
    }
}
