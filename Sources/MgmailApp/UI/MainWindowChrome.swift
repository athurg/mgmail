import SwiftUI
import AppKit

/// 主窗口的「壳」：把三个圆点挪进侧栏顶上那张卡片里。
///
/// 标题栏藏着的时候圆点贴在窗口左上角（x≈8、y≈8），而侧栏顶上的分组卡片和中栏面板
/// 一样从 10pt 开始铺，圆点就骑在卡片的角上。圆点住在标题栏视图里，那块只有 28pt 高，
/// 直接改它们的 frame 往下挪，挪出去的部分就点不着了。给窗口挂一个空的统一样式工具栏，
/// 标题栏会长到 52pt、圆点自己垂直居中（中心约在 x≈25、y≈25，右端到 x≈76），正好落进
/// 卡片那一行；工具栏本身什么都不画，也不带分隔线。
///
/// 全屏时摘掉：全屏里鼠标碰到顶边标题栏会滑出来，空工具栏跟着露出一条 52pt 的空条；
/// 圆点在全屏里本来就不显示，用不着它撑高度。退出全屏再挂回去。
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
            if !window.styleMask.contains(.fullScreen) { attachToolbar(window) }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window,
                                   queue: .main) { [weak window] _ in window?.toolbar = nil },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                                   queue: .main) { [weak self, weak window] _ in
                    if let window { self?.attachToolbar(window) }
                },
            ]
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        private func attachToolbar(_ window: NSWindow) {
            guard window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "MainWindowChrome")
            toolbar.showsBaselineSeparator = false
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.toolbar = toolbar
        }
    }
}
