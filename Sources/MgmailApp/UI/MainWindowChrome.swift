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
/// 所以直接改标题栏：外层容器加高，装着圆点的那层整体往下、往右挪一点。窗口改大小、
/// 缩放、进出全屏、切屏时 AppKit 会把这两层排回默认位置，还会按「离窗口左上角 (16, 16)」
/// 重摆三个圆点本身——圆点跟着回到卡片上沿。这里盯着窗口的这些事件和几层视图的 frame
/// 变化，一被改回去就立刻再摆一次；圆点的目标位置是它们在装圆点那层里的原始偏移。
struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        private var layout: TitlebarLayout?
        private var windowObservers: [NSObjectProtocol] = []
        private var frameObservers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            layout = nil
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            // 标题栏不再接鼠标，窗口得另找地方拖：按在桌布或面板头这种没控件的地方就能拖
            window.isMovableByWindowBackground = true
            guard let layout = TitlebarLayout(window: window) else { return }
            self.layout = layout
            reapply()
            // AppKit 在这些时机会重排标题栏和圆点。有的（缩放动画）会发 frame 通知，
            // 有的（分屏平铺、切屏）只在事后能看出来，所以事件本身也当触发点，
            // 并且各推迟一拍再查一次——AppKit 有时在通知发出之后才动手。
            let center = NotificationCenter.default
            let triggers: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeMainNotification,
            ]
            windowObservers = triggers.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.reapply()
                }
            }
        }

        /// 摆一次，并把 frame 监听换到当前这几层视图上（退出全屏 AppKit 会整个重建标题栏，
        /// 旧的视图对象已经不在窗口里了），再排一拍之后复查。
        private func reapply() {
            guard let layout else { return }
            layout.apply()
            watchFrames(of: layout.watched)
            DispatchQueue.main.async { [weak self] in self?.layout?.apply() }
        }

        private func watchFrames(of views: [NSView]) {
            frameObservers.forEach(NotificationCenter.default.removeObserver)
            // apply 只在位置不对时才改，改完发的那次通知看到位置已对就不会再动，不会绕圈。
            frameObservers = views.map { view in
                view.postsFrameChangedNotifications = true
                return NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: nil
                ) { [weak self] _ in self?.layout?.apply() }
            }
        }

        private func removeObservers() {
            (windowObservers + frameObservers).forEach(NotificationCenter.default.removeObserver)
            windowObservers = []
            frameObservers = []
        }

        deinit { removeObservers() }
    }

    /// 标题栏两层和三个圆点的目标位置。
    ///
    /// 圆点住在 NSTitlebarView 里，AppKit 在这层里按固定偏移摆它们（中心离顶 16、左起 9）；
    /// 这层的上一层是决定标题栏高度的容器。容器加高到 50，装圆点那层保持原高度、
    /// 往下挪到圆点中心落在 y=25，再往右挪 10 让圆点落进卡片内沿里面（左起 19）。
    ///
    /// 视图对象每次都从窗口重新找，不缓存：AppKit 重建标题栏后旧对象就作废了。
    private struct TitlebarLayout {
        static let height: CGFloat = 50
        static let buttonCenterY: CGFloat = 25
        static let insetX: CGFloat = 10
        private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        let window: NSWindow
        /// 装圆点那层的原始高度、圆点中心离它顶边多远、三个圆点在这层里的原始位置——
        /// 都是 AppKit 定的，进来时量一次，之后就按这个摆回去。
        let titlebarHeight: CGFloat
        let buttonOffsetFromTop: CGFloat
        let buttonFrames: [NSWindow.ButtonType: NSRect]

        init?(window: NSWindow) {
            guard let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview else { return nil }
            self.window = window
            titlebarHeight = titlebar.frame.height
            buttonOffsetFromTop = titlebar.frame.height - close.frame.midY
            buttonFrames = Dictionary(uniqueKeysWithValues: Self.buttonTypes.compactMap { type in
                window.standardWindowButton(type).map { (type, $0.frame) }
            })
        }

        /// 当前窗口里的那几层：装圆点的那层、它的容器、三个圆点。
        private var views: (container: NSView, titlebar: NSView, buttons: [(NSWindow.ButtonType, NSView)])? {
            guard let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return nil }
            let buttons = Self.buttonTypes.compactMap { type in
                window.standardWindowButton(type).map { (type, $0) }
            }
            return (container, titlebar, buttons)
        }

        /// 要盯 frame 变化的视图。
        var watched: [NSView] {
            guard let views else { return [] }
            return [views.container, views.titlebar] + views.buttons.map(\.1)
        }

        /// 摆到位；已经在位的一个都不碰（frame 通知就是从这儿收敛的）。
        func apply() {
            // 全屏里圆点由系统藏起来，标题栏也不归这儿管
            guard !window.styleMask.contains(.fullScreen),
                  let frameView = window.contentView?.superview, let views else { return }
            let containerFrame = NSRect(x: 0, y: frameView.bounds.height - Self.height,
                                        width: frameView.bounds.width, height: Self.height)
            if views.container.frame != containerFrame { views.container.frame = containerFrame }

            // 容器坐标 y 向上：这层的顶边要在 (容器高 - (目标中心 - 圆点离顶偏移)) 处
            let top = Self.height - (Self.buttonCenterY - buttonOffsetFromTop)
            let titlebarFrame = NSRect(x: Self.insetX, y: top - titlebarHeight,
                                       width: containerFrame.width - Self.insetX, height: titlebarHeight)
            if views.titlebar.frame != titlebarFrame { views.titlebar.frame = titlebarFrame }

            for (type, button) in views.buttons {
                guard let frame = buttonFrames[type], button.frame != frame else { continue }
                button.frame = frame
            }
        }
    }
}
