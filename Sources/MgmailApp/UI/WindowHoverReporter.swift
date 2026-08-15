import SwiftUI
import AppKit

/// 报告「鼠标在不在这扇窗里」。
///
/// 给悬停才现身的标题栏按钮用。不能用 SwiftUI 的 `.onHover`：那些按钮长在标题栏上，
/// 那块地方不属于内容视图，鼠标从正文往按钮上挪的半路，内容这边就先判定为「离开」，
/// 按钮会在手指还没到的时候淡掉。
///
/// 所以铺一张贴着窗口四边的透明垫子（放在 `.background` 里配 `.ignoresSafeArea()`，
/// 它的范围就连标题栏一起盖住），在它自己身上挂 tracking area。上面压着的按钮不影响
/// 这里收事件——tracking area 按几何范围算，不做遮挡判断。
struct WindowHoverReporter: NSViewRepresentable {
    @Binding var inside: Bool

    func makeNSView(context: Context) -> NSView {
        TrackingView { value in
            // 鼠标动得比 SwiftUI 的一帧快，同一状态会连报几次，滤掉免得白刷新
            if inside != value { inside = value }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        private let onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // activeAlways：这扇窗没在最前面时，鼠标扫过去也该把按钮亮出来，
            // 不然用户得先点一下激活窗口才看得见能按什么。
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
            // tracking area 只报「进出」，装上的那一刻鼠标已经在里面的话它不补发。
            // 双击列表开窗、手不动，恰恰就是这种情形，所以自己对一次表。
            syncFromPointer()
        }

        private func syncFromPointer() {
            guard let window else { return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            onChange(bounds.contains(point))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }

        /// 窗口在鼠标底下被关掉/移开时不会有 exited，离场时自己收尾。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { onChange(false) }
        }
    }
}
