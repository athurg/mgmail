import SwiftUI

/// 窗口底部的网络活动栏：有活动时出现，说明此刻在替哪个账号做什么。
///
/// 只在有事发生时占位，闲下来就收起——常驻一条空栏会一直挤着邮件列表。
/// 活动结束后故意多留一会儿再收：刷新是一串短请求，请求之间的空隙若立刻收栏，
/// 用户看到的就是一条来回闪的栏。
struct ActivityStatusBar: View {
    @ObservedObject private var log = ActivityLog.shared
    @Environment(\.openWindow) private var openWindow

    /// 栏是否可见（比「有没有活动」滞后一点，见上面的注释）。
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?
    /// 正在展示的失败提示（活动停下来之后仍停留几秒）。
    @State private var failure: ActivityEntry?
    @State private var failureTask: Task<Void, Never>?

    /// 活动停下多久后收起栏。
    private static let lingering: Duration = .milliseconds(900)
    /// 失败提示停留多久。
    private static let failureLinger: Duration = .seconds(8)

    var body: some View {
        VStack(spacing: 0) {
            if visible {
                Divider()
                content
                    .frame(height: 24)
                    .background(.bar)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: visible)
        .onChange(of: log.running.isEmpty, initial: true) { _, idle in
            hideTask?.cancel()
            guard idle else {
                visible = true
                return
            }
            hideTask = Task {
                try? await Task.sleep(for: Self.lingering)
                guard !Task.isCancelled else { return }
                // 还有失败提示要展示时先不收
                if log.running.isEmpty && failure == nil { visible = false }
            }
        }
        .onChange(of: log.lastFailure) { _, entry in
            guard let entry else { return }
            failure = entry
            visible = true
            failureTask?.cancel()
            failureTask = Task {
                try? await Task.sleep(for: Self.failureLinger)
                guard !Task.isCancelled else { return }
                failure = nil
                if log.running.isEmpty { visible = false }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            if !log.running.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            } else if failure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(failure != nil && log.running.isEmpty ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if log.running.count > 1 {
                Text("还有 \(log.running.count - 1) 项")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button("活动日志") { openWindow(id: ActivityWindow.id) }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("查看全部网络活动记录")
        }
        .padding(.horizontal, 12)
    }

    /// 优先报当前在做什么；都做完了才轮到失败提示，最后是刚做完的那件事。
    private var message: String {
        if let current = log.running.first {
            return "正在\(current.title)" + (current.account.map { " · \($0)" } ?? "")
        }
        if let failure {
            let who = failure.account.map { "（\($0)）" } ?? ""
            return "\(failure.title)失败\(who)：\(failure.errorText ?? "")"
        }
        if let last = log.entries.last {
            return "已完成\(last.title)" + (last.account.map { " · \($0)" } ?? "")
        }
        return "空闲"
    }
}
