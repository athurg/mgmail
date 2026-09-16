import SwiftUI
import AppKit

/// 主窗口的「壳」：把三个圆点挪进侧栏顶上那张卡片里。
///
/// 标题栏藏着的时候标题栏只有 32pt 高，圆点中心在 y≈16，而侧栏顶上的分组卡片和中栏面板
/// 一样从 10pt 开始铺，圆点就骑在卡片的上沿。想让它们落进卡片第一行（中心 y≈25），
/// 得把标题栏加高、圆点往下挪。
///
/// 不能靠挂一个空工具栏来加高：工具栏一挂上，整条标题栏（macOS 26 上有 66pt 高）
/// 都归它接鼠标，按在下面的东西一律当成拖窗口——面板头里的回复/星标/标签、列表头的
/// 过滤和新建、分组标签，全都点不动。没有工具栏的标题栏才会把点击放行给下面的内容。
///
/// 所以直接改标题栏：外层容器加高，装着圆点的那层整体往下、往右挪一点。圆点本身不碰——
/// 它们的位置由 AppKit 按所在那层的坐标排，直接改会被它改回去。窗口改大小、进出全屏时
/// AppKit 会把这两层重新排回默认位置，这里盯着它们的 frame 变化，一被改回去就立刻再摆一次。
struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            // 标题栏不再接鼠标，窗口得另找地方拖：按在桌布或面板头这种没控件的地方就能拖
            window.isMovableByWindowBackground = true
            guard let layout = TitlebarLayout(window: window) else { return }
            layout.apply()
            let center = NotificationCenter.default
            // 两层任何一个被 AppKit 排回去都会发 frame 通知，当场再摆一次；
            // apply 只在位置不对时才改，改完发的那次通知看到位置已对就不会再动，不会绕圈。
            observers = layout.watched.map { view in
                view.postsFrameChangedNotifications = true
                return center.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                          queue: nil) { _ in layout.apply() }
            }
            // 退出全屏 AppKit 会整个重建标题栏，等它建完再摆
            observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                object: window, queue: .main) { _ in layout.apply() })
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    /// 标题栏两层的目标位置。
    ///
    /// 圆点住在 NSTitlebarView 里，AppKit 在这层里按固定偏移摆它们（中心离顶 16、左起 9）；
    /// 这层的上一层是决定标题栏高度的容器。容器加高到 50，装圆点那层保持原高度、
    /// 往下挪到圆点中心落在 y=25，再往右挪 10 让圆点落进卡片内沿里面（左起 19）。
    private struct TitlebarLayout {
        static let height: CGFloat = 50
        static let buttonCenterY: CGFloat = 25
        static let insetX: CGFloat = 10

        let window: NSWindow
        let container: NSView
        let titlebar: NSView
        /// 装圆点那层的原始高度，以及圆点中心离它顶边多远——都是 AppKit 定的，进来时量一次。
        let titlebarHeight: CGFloat
        let buttonOffsetFromTop: CGFloat

        init?(window: NSWindow) {
            guard let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return nil }
            self.window = window
            self.container = container
            self.titlebar = titlebar
            titlebarHeight = titlebar.frame.height
            buttonOffsetFromTop = titlebar.frame.height - close.frame.midY
        }

        var watched: [NSView] { [container, titlebar] }

        /// 摆到位；已经在位的一个都不碰（frame 通知就是从这儿收敛的）。
        func apply() {
            // 全屏里圆点由系统藏起来，标题栏也不归这儿管
            guard !window.styleMask.contains(.fullScreen),
                  let frameView = window.contentView?.superview else { return }
            let containerFrame = NSRect(x: 0, y: frameView.bounds.height - Self.height,
                                        width: frameView.bounds.width, height: Self.height)
            if container.frame != containerFrame { container.frame = containerFrame }

            // 容器坐标 y 向上：这层的顶边要在 (容器高 - (目标中心 - 圆点离顶偏移)) 处
            let top = Self.height - (Self.buttonCenterY - buttonOffsetFromTop)
            let titlebarFrame = NSRect(x: Self.insetX, y: top - titlebarHeight,
                                       width: containerFrame.width - Self.insetX, height: titlebarHeight)
            if titlebar.frame != titlebarFrame { titlebar.frame = titlebarFrame }
        }
    }
}
