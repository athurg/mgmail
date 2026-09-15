import SwiftUI

/// 三栏共用的「底色 + 玻璃卡片」皮肤（参考 Telegram macOS：一张浅色渐变的桌布，
/// 上面浮着一张张玻璃卡片）。
///
/// 为什么要自己铺底色：系统的侧栏材质在窗口失焦时会退成一块平灰，玻璃卡片放上去
/// 几乎看不见了；自己铺一层渐变，激活与否都是同一张桌布，卡片始终有东西可「透」。
/// 整窗只铺一张（在 RootView），三栏都浮在它上面。
struct WindowBackdrop: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> GradientView { GradientView() }

    func updateNSView(_ view: GradientView, context: Context) {
        view.colors = Self.colors(for: scheme)
    }

    private static func colors(for scheme: ColorScheme) -> [NSColor] {
        switch scheme {
        case .dark:
            return [NSColor(hue: 0.62, saturation: 0.22, brightness: 0.19, alpha: 1),
                    NSColor(hue: 0.42, saturation: 0.18, brightness: 0.15, alpha: 1)]
        default:
            return [NSColor(hue: 0.60, saturation: 0.15, brightness: 0.96, alpha: 1),
                    NSColor(hue: 0.36, saturation: 0.13, brightness: 0.93, alpha: 1)]
        }
    }

    /// 用 AppKit 视图而不是 SwiftUI 的 LinearGradient 画：侧栏那一栏套在系统的
    /// NSVisualEffectView 里，SwiftUI 画的颜色会被它做「活力」混色，整块被提亮、
    /// 和中栏右栏对不上色；普通 NSView 默认不参与混色，三栏才能是同一张桌布。
    final class GradientView: NSView {
        var colors: [NSColor] = [] {
            didSet {
                (layer as? CAGradientLayer)?.colors = colors.map(\.cgColor)
                syncWindowBackground()
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var allowsVibrancy: Bool { false }

        /// 渐变直接当视图的 backing layer，而不是挂一个子层再在 layout() 里手动对 frame：
        /// 子层的 frame 改动会走 Core Animation 的隐式动画（0.25s），拖窗口时新露出来的
        /// 那一截要等动画追上才被盖住，中间就是窗口的白底一闪。backing layer 由 AppKit
        /// 跟着视图同步改大小，没有这层延迟。
        override func makeBackingLayer() -> CALayer {
            let gradient = CAGradientLayer()
            // 层坐标 y 向上：(0.5, 1) 是顶边，颜色数组第一个落在上面
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = colors.map(\.cgColor)
            return gradient
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncWindowBackground()
        }

        /// 窗口自己的底色也调成桌布的顶色：拖大窗口时 AppKit 先用窗口底色填新露出的
        /// 区域，再等内容画上去；底色和桌布同色，这一帧就看不出来。
        private func syncWindowBackground() {
            guard let window, let top = colors.first else { return }
            window.backgroundColor = top
        }
    }
}

/// 玻璃卡片的材质：macOS 26 起用系统的 Liquid Glass；再老的系统退回普通半透明材质
/// 加一圈细边和淡影，形状一致。
struct GlassCard: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }
}

extension View {
    /// 一张玻璃卡片。
    func glassCard(radius: CGFloat = 12) -> some View {
        modifier(GlassCard(radius: radius))
    }

    /// 整栏一张玻璃面板：内容裁成圆角、垫玻璃、四周留出桌布。
    /// 中栏的邮件列表、右栏的正文都用它，和侧栏的卡片是同一套材质、同一个圆角。
    func glassPanel(inset: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .clipShape(shape)
            .glassCard()
            .padding(inset)
    }
}
