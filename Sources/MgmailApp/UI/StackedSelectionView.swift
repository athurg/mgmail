import SwiftUI
import AppKit

/// 多选时右栏的「叠加邮件卡片」效果（仿 Apple Mail）。
struct StackedSelectionView: View {
    let infos: [SelectedThreadInfo]
    let total: Int

    /// 最多画几张卡片。
    private let maxCards = 5
    /// 每张卡片相对上一张的偏移与角度（自然的手叠效果）。
    private let angles: [Double] = [0, -3.5, 3, -2, 4]

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            stack
            VStack(spacing: 4) {
                Text("已选择 \(total) 封邮件").font(.title3).bold()
                Text("在中栏工具栏或右键菜单进行批量操作")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var stack: some View {
        let cards = Array(infos.prefix(maxCards))
        return ZStack {
            ForEach(Array(cards.enumerated()), id: \.element) { idx, info in
                card(info, isFront: idx == 0)
                    .frame(width: 360, height: 190)
                    .scaleEffect(1 - CGFloat(idx) * 0.04)
                    .rotationEffect(.degrees(angles[min(idx, angles.count - 1)]))
                    .offset(y: CGFloat(idx) * -10)
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
                    .zIndex(Double(-idx))
            }
        }
        .frame(height: 240)
    }

    private func card(_ info: SelectedThreadInfo, isFront: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(info.from.isEmpty ? "（未知发件人）" : info.from)
                            .font(.callout).bold().lineLimit(1)
                        Spacer()
                        Text(dateText(info.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(info.subject.isEmpty ? "（无主题）" : info.subject)
                        .font(.callout).lineLimit(2)
                    // 几条占位文本线，暗示正文
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 8)
                        }
                    }
                    .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .opacity(isFront ? 1 : 0.97)
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}
