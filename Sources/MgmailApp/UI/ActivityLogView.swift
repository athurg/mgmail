import SwiftUI
import AppKit

/// 活动窗口的标识（菜单与底部栏都要用它开窗）。
enum ActivityWindow {
    static let id = "activity"
}

/// 活动日志窗口（仿 Apple Mail 的「活动」）：一行一次网络往返，可按账号/类别/关键词查。
struct ActivityLogView: View {
    @ObservedObject private var log = ActivityLog.shared

    @State private var search = ""
    @State private var kindFilter: ActivityKind?
    @State private var accountFilter = ""      // 空串 = 全部账号
    @State private var onlyFailures = false
    @State private var selection: ActivityEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
            Divider()
            detail
        }
        .frame(minWidth: 720, minHeight: 380)
    }

    // MARK: - 过滤条

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索活动、账号或错误", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Picker("", selection: $accountFilter) {
                Text("全部账号").tag("")
                ForEach(accounts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            Picker("", selection: $kindFilter) {
                Text("全部类别").tag(ActivityKind?.none)
                ForEach(ActivityKind.allCases) { kind in
                    Text(kind.title).tag(ActivityKind?.some(kind))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 130)

            Toggle("只看失败", isOn: $onlyFailures)
                .toggleStyle(.checkbox)

            Spacer()

            Text("\(filtered.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("清除") { log.clear() }
                .help("清空窗口里的记录（磁盘上的日志文件保留）")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([ActivityLogFile.directory])
            } label: {
                Image(systemName: "folder")
            }
            .help("在访达中显示日志文件")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 表格

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("") { entry in
                Image(systemName: entry.kind.systemImage)
                    .foregroundStyle(color(for: entry))
                    .help(entry.kind.title)
            }
            .width(20)

            TableColumn("时间") { entry in
                Text(Self.time.string(from: entry.startedAt))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(72)

            TableColumn("账号") { entry in
                Text(entry.account ?? "—").lineLimit(1).truncationMode(.middle)
            }
            .width(min: 120, ideal: 180)

            TableColumn("活动") { entry in
                Text(entry.title).lineLimit(1)
            }
            .width(min: 150, ideal: 230)

            TableColumn("状态") { entry in
                HStack(spacing: 4) {
                    Text(entry.statusText).foregroundStyle(color(for: entry))
                    if entry.retries > 0 {
                        Text("重试 \(entry.retries)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 80, ideal: 110)

            TableColumn("耗时") { entry in
                Text(Self.durationText(entry)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(70)

            TableColumn("大小") { entry in
                Text(entry.bytes > 0 ? Self.byteText(entry.bytes) : "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(70)
        }
        .tableStyle(.inset)
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        if let entry = filtered.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title).fontWeight(.medium)
                    Text(entry.kind.title)
                        .font(.caption)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    Text(Self.full.string(from: entry.startedAt))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("\(entry.method) \(entry.url)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                if let error = entry.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("选中一行查看请求详情")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    // MARK: - 数据

    /// 新的在上；筛选全在本地，日志本身不会因为查询而改变。
    private var filtered: [ActivityEntry] {
        var items = log.entries
        if let kindFilter { items = items.filter { $0.kind == kindFilter } }
        if !accountFilter.isEmpty { items = items.filter { $0.account == accountFilter } }
        if onlyFailures { items = items.filter(\.isFailure) }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            items = items.filter { entry in
                entry.title.lowercased().contains(query)
                    || (entry.account ?? "").lowercased().contains(query)
                    || entry.url.lowercased().contains(query)
                    || (entry.errorText ?? "").lowercased().contains(query)
            }
        }
        return items.reversed()
    }

    private var accounts: [String] {
        Array(Set(log.entries.compactMap(\.account))).sorted()
    }

    private func color(for entry: ActivityEntry) -> Color {
        if entry.isFailure { return .red }
        if entry.isRunning { return .accentColor }
        return .secondary
    }

    // MARK: - 格式化

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func durationText(_ entry: ActivityEntry) -> String {
        guard let seconds = entry.duration else { return "…" }
        return seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.1f s", seconds)
    }

    private static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
