import SwiftUI
import AppKit

/// 多选时右栏的「叠加邮件卡片」效果（仿 Apple Mail）。
///
/// 卡片不是凭空冒出来的：每一张都从它在中栏列表里的那一行飞过来，
/// 一路放大、转正，到位就停住；取消多选时再各自缩回自己那一行。
/// 起降点由 `ThreadRowFrames` 提供，行滚出可视区域时退化成从侧边斜飞。
struct StackedSelectionView: View {
    let infos: [SelectedThreadInfo]
    let total: Int
    /// 正在退场：卡片各自飞回列表，飞完回调 `onLeaveFinished` 通知外面撤掉本视图。
    let isLeaving: Bool
    let onLeaveFinished: () -> Void

    /// 最多画几张卡片。
    private let maxCards = 5
    /// 每张卡片相对上一张的偏移与角度（自然的手叠效果）。
    private let angles: [Double] = [0, -3.5, 3, -2, 4]
    /// 卡片高度固定，宽度随右栏收放（窄窗口下不至于顶到边）。
    private static let cardHeight: CGFloat = 300
    private static let maxCardWidth: CGFloat = 560
    /// 后一张卡片相对前一张往上错开多少。
    private static let stackStep: CGFloat = 14

    /// 落位、返程都用临界阻尼的弹簧：只减速，不过冲，落到位就停住。
    private static let land = Animation.spring(response: 0.58, dampingFraction: 1)
    private static let leave = Animation.spring(response: 0.46, dampingFraction: 1)
    /// 返程实际耗时（含最后一张卡片错开的那点时间），到点才通知外面撤掉本视图。
    ///
    /// 不用 `withAnimation` 的 completion：转场的移除不计入它的完成判定，
    /// 回调当场就回来了，视图立刻被撤，卡片一帧都没飞。
    /// 改快改慢 `leave` 时这个数要跟着走，比动画短的话卡片会被截断在半路。
    private static let leaveDuration = Duration.milliseconds(1000)
    /// 相邻两张卡片错开的起飞时间。
    private static let stagger = 0.06

    /// 真正画出来的卡片。与 `infos` 分开，才能在视图出现后再填进去——
    /// 直接用 `infos` 的话，整个视图是作为一体插入的，内部的转场根本不会播。
    @State private var displayed: [SelectedThreadInfo] = []
    /// 文案里的数字。退场途中 `total` 已经变成新选中的那一封了，不跟。
    @State private var shownTotal = 0

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            stack
            caption
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear { shownTotal = total; sync() }
        .onChange(of: infos) { _, _ in sync() }
        .onChange(of: isLeaving) { _, _ in sync() }
        .onChange(of: total) { _, new in if !isLeaving { shownTotal = new } }
    }

    private var caption: some View {
        VStack(spacing: 4) {
            Text("已选择 \(shownTotal) 封邮件")
                .font(.title3).bold()
                .contentTransition(.numericText())
            Text("在中栏工具栏或右键菜单进行批量操作")
                .font(.caption).foregroundStyle(.secondary)
        }
        .opacity(isLeaving ? 0 : 1)
        .animation(Self.land, value: shownTotal)
        .animation(Self.leave, value: isLeaving)
    }

    /// 把最新的选择搬进 `displayed`，多出来、少掉的卡片各自播放起降。
    private func sync() {
        guard !isLeaving else {
            guard !displayed.isEmpty else { onLeaveFinished(); return }
            withAnimation(Self.leave) { displayed = [] }
            let finished = onLeaveFinished
            Task { @MainActor in
                try? await Task.sleep(for: Self.leaveDuration)
                finished()
            }
            return
        }
        let next = Array(infos.prefix(maxCards))
        guard next != displayed else { return }
        withAnimation(Self.land) { displayed = next }
    }

    private var stack: some View {
        GeometryReader { geo in
            // 牌堆此刻在窗口里的位置，用来把行的绝对坐标换算成相对位移
            let here = geo.frame(in: .global)
            let width = min(Self.maxCardWidth, max(280, geo.size.width - 48))
            ZStack {
                ForEach(Array(displayed.enumerated()), id: \.element) { idx, info in
                    card(info, isFront: idx == 0)
                        .frame(width: width, height: Self.cardHeight)
                        .scaleEffect(1 - CGFloat(idx) * 0.04)
                        .rotationEffect(.degrees(angle(idx)))
                        .offset(y: CGFloat(idx) * -Self.stackStep)
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
                        .zIndex(Double(-idx))
                        .transition(.flight(plan(for: info, idx: idx, stack: here)))
                        // 越靠后的卡片越晚起飞，才有「一张张」的层次感。
                        .transaction { t in
                            guard t.animation != nil else { return }
                            t.animation = (isLeaving ? Self.leave : Self.land)
                                .delay(Double(idx) * Self.stagger)
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.cardHeight + Self.stackStep * CGFloat(maxCards - 1))
    }

    private func angle(_ idx: Int) -> Double { angles[min(idx, angles.count - 1)] }

    /// 这张卡片的起降点：它在中栏列表里那一行。
    ///
    /// 位移是相对「落位后的卡片中心」算的——牌堆中心再按叠放顺序往上错一点；
    /// 缩放取行高与卡片高之比，看起来就像卡片是从那一行里长出来的。
    private func plan(for info: SelectedThreadInfo, idx: Int, stack: CGRect) -> CardFlight {
        let key = SelectedThread(accountID: info.accountID, threadID: info.threadID)
        guard stack.width > 0, let row = ThreadRowFrames.shared.frame(for: key) else {
            return CardFlight(offset: CGSize(width: -320, height: 70), scale: 0.4, angle: -16)
        }
        let center = CGPoint(x: stack.midX, y: stack.midY - CGFloat(idx) * Self.stackStep)
        return CardFlight(
            offset: CGSize(width: row.midX - center.x, height: row.midY - center.y),
            scale: max(0.12, row.height / Self.cardHeight),
            // 贴回行上时把卡片自己那点倾斜抵消掉，躺平进列表
            angle: -angle(idx)
        )
    }

    private func card(_ info: SelectedThreadInfo, isFront: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(info.from.isEmpty ? "（未知发件人）" : info.from)
                            .font(.body).bold().lineLimit(1)
                        Spacer()
                        Text(DateText.card(info.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(info.subject.isEmpty ? "（无主题）" : info.subject)
                        .font(.body).lineLimit(2)
                    // 几条占位文本线，暗示正文
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 9)
                                // 最后一条短一些，像段落的末行
                                .frame(maxWidth: i == 6 ? 160 : .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .opacity(isFront ? 1 : 0.97)
    }
}

// MARK: - 起降转场

/// 一张卡片起飞前、降落后停在哪儿：相对落位处的位移、缩到多小、额外转多少度。
struct CardFlight: Equatable {
    var offset: CGSize
    var scale: CGFloat
    var angle: Double
}

private struct CardFlightModifier: ViewModifier {
    let flight: CardFlight
    /// true 是「在行里」那一端，false 是「落在牌堆里」那一端。
    let inRow: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(inRow ? flight.scale : 1)
            .rotationEffect(.degrees(inRow ? flight.angle : 0))
            .offset(x: inRow ? flight.offset.width : 0,
                    y: inRow ? flight.offset.height : 0)
            .opacity(inRow ? 0 : 1)
            .blur(radius: inRow ? 3 : 0)
    }
}

extension AnyTransition {
    /// 卡片在「列表里的那一行」和「牌堆里的位置」之间往返。
    static func flight(_ flight: CardFlight) -> AnyTransition {
        .modifier(active: CardFlightModifier(flight: flight, inRow: true),
                  identity: CardFlightModifier(flight: flight, inRow: false))
    }
}
