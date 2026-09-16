import SwiftUI
import AppKit

/// 让独立窗口（设置、关于这类单例窗口）开在主窗口所在的那块屏幕上。
///
/// SwiftUI 的设置窗口自己记位置：上次关在哪块屏，下次就在哪块屏开。主窗口挪到另一台显示器
/// 之后按 ⌘, 看着像没反应——设置窗口开在了看不见的那块屏上（关掉的副屏、合上的笔记本，
/// 或者只是没扭头看）。这里在窗口出来那一刻看它落在哪块屏，不是正在用的那扇窗所在的那块
/// 就挪过去，居中盖在那扇窗上。只在出来那一刻挪一次：之后用户手动拖去别的屏是他的选择，
/// 不追着改；关掉再开算重新出来，再看一次。
///
/// 挂法：`.background(FollowMainScreen())`；不归 SwiftUI 管的窗口直接调 `moveToHostScreen`。
struct FollowMainScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PlacementView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PlacementView: NSView {
        private var observers: [NSObjectProtocol] = []
        /// 下次排上屏时要不要摆位置：刚挂上窗口、以及每次被关掉之后为真。
        ///
        /// SwiftUI 关掉设置窗口只是把它藏起来，下次 ⌘, 还是同一扇，视图不会重新挂载；
        /// 用户这期间把主窗口拖去了另一块屏，重开时得再看一次。摆过一次就清掉，
        /// 之后在两扇窗之间来回切换、被别的窗口盖住再露出来都不再动它。
        private var pending = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            pending = true
            let center = NotificationCenter.default
            // 挂上窗口时 SwiftUI 还没把记住的位置恢复回来，这时挪了也会被它盖掉；等窗口真正
            // 排上屏再看它落在哪。排上屏的信号是遮挡状态变化（从「不在屏上」变成「可见」）——
            // 应用不在前台时窗口出来也不成为焦点，只盯 didBecomeKey 会漏掉；两个都听，谁先到谁算。
            let place: (Notification) -> Void = { [weak self] _ in
                guard let self, self.pending, window.isVisible else { return }
                self.pending = false
                FollowMainScreen.moveToHostScreen(window)
            }
            observers = [
                center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                   queue: .main, using: place),
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                   queue: .main, using: place),
                center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                   queue: .main) { [weak self] _ in self?.pending = true },
            ]
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    }

    /// 不在正在用的那扇窗所在的屏幕上，就居中盖到那扇窗上去（不越出那块屏的可用区域）。
    ///
    /// 不是 SwiftUI 场景的窗口（AppKit 自带的「关于」面板）挂不上视图，弹出之后直接调这个。
    static func moveToHostScreen(_ window: NSWindow) {
        guard let host = ModalHost.window(excluding: window),
              let hostScreen = host.screen,
              screen(containing: window.frame) !== hostScreen else { return }
        var frame = window.frame
        frame.origin = CGPoint(x: host.frame.midX - frame.width / 2, y: host.frame.midY - frame.height / 2)
        let area = hostScreen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, area.minY), area.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    /// 窗口算在哪块屏上：看它中心点落在哪。`NSWindow.screen` 在窗口还没排上屏时是空的，不能用。
    private static func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }
}
