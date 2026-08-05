import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 收集每一行在列表坐标系里的位置，供拖拽层做命中判断。
struct RowFramesKey: PreferenceKey {
    static let defaultValue: [SelectedThread: CGRect] = [:]
    static func reduce(value: inout [SelectedThread: CGRect],
                       nextValue: () -> [SelectedThread: CGRect]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// 覆盖在会话列表之上、只负责「把邮件拖出去」的一层。
///
/// 为什么不用 SwiftUI 的 `.draggable` / `.onDrag` / `.itemProvider`：
/// 那些 modifier 挂在 List 行上，而 macOS 的 List 由 NSTableView 支撑 ——
/// 每次改选中 SwiftUI 都要重算行，行上的拖放注册也跟着重做，
/// 而这发生在 NSTableView 的选择回调内部，AppKit 会中断并重做整表
/// （日志里的 "reentrant operation in its NSTableView delegate"），
/// 表现出来就是「点一封邮件整个界面刷新一下」。三种拖拽 API 实测都如此。
///
/// 这一层不属于任何一行，行怎么重建都与它无关；它对命中测试完全透明，
/// 只在鼠标按下的瞬间短暂接管事件跟踪，判定是拖拽还是普通点击。
struct ThreadDragLayer: NSViewRepresentable {
    /// 命中判断：给定列表坐标，返回该处是哪一行。
    var rowAt: (CGPoint) -> SelectedThread?
    /// 拖拽开始时构造载荷（会把单行扩展成整组多选）。
    var makePayload: (SelectedThread) -> ThreadDragPayload?

    func makeNSView(context: Context) -> NSView {
        let view = DragLayerView()
        view.rowAt = rowAt
        view.makePayload = makePayload
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragLayerView else { return }
        view.rowAt = rowAt
        view.makePayload = makePayload
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? DragLayerView)?.removeMonitor()
    }
}

private final class DragLayerView: NSView, NSDraggingSource {
    var rowAt: ((CGPoint) -> SelectedThread?)?
    var makePayload: ((SelectedThread) -> ThreadDragPayload?)?

    private var monitor: Any?

    /// 与 SwiftUI 一致的坐标方向（原点左上、Y 向下）。
    override var isFlipped: Bool { true }

    /// 不参与命中测试：点击、右键、滚动照常落到下面的列表。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeMonitor() } else { installMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        // 只拦按下这一下。被动监听拿不到后续的拖动事件——NSTableView 的 mouseDown
        // 会进入自己的事件跟踪循环，把 mouseDragged 直接取走，监听器根本收不到。
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.intercept(event) } ? nil : event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 在按下的瞬间自己跟踪一小段事件流，判断这是拖拽还是普通点击。
    /// 返回 true 表示已作为拖拽消费掉这次按下（列表不会收到，也就不会改选中——
    /// 与 Finder、Gmail 一致：拖动一行不改变当前选中）。
    private func intercept(_ event: NSEvent) -> Bool {
        guard let window, window === event.window else { return false }
        let start = Self.swiftUIPoint(event.locationInWindow, in: window)
        guard let key = rowAt?(start) else { return false }

        var startedDrag = false
        var pendingUp: NSEvent?

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { tracked, stop in
            guard let tracked else { stop.pointee = true; return }
            switch tracked.type {
            case .leftMouseDragged:
                let now = Self.swiftUIPoint(tracked.locationInWindow, in: window)
                guard hypot(now.x - start.x, now.y - start.y) > 4 else { return } // 抖动阈值
                startedDrag = MainActor.assumeIsolated {
                    self.beginDrag(row: key, from: start, event: tracked)
                }
                stop.pointee = true
            case .leftMouseUp:
                pendingUp = tracked
                stop.pointee = true
            default:
                break
            }
        }

        // 普通点击：把松开原样放回队列，随后返回 false 让按下继续分发，
        // 列表于是像什么都没发生过一样完成自己的选中流程。
        if let pendingUp { NSApp.postEvent(pendingUp, atStart: true) }
        return startedDrag
    }

    /// AppKit 窗口坐标（原点左下）→ SwiftUI 的 .global 坐标（原点左上）。
    private static func swiftUIPoint(_ p: NSPoint, in window: NSWindow) -> CGPoint {
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGPoint(x: p.x, y: height - p.y)
    }

    private func beginDrag(row key: SelectedThread, from point: CGPoint, event: NSEvent) -> Bool {
        guard let payload = makePayload?(key),
              let data = try? JSONEncoder().encode(payload) else { return false }

        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.mgmailThreads.identifier))

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = Self.previewImage(count: payload.items.count)
        // 预览框要用本视图自己的坐标
        let local = convert(event.locationInWindow, from: nil)
        let origin = CGPoint(x: local.x - image.size.width / 2, y: local.y - image.size.height / 2)
        dragItem.setDraggingFrame(CGRect(origin: origin, size: image.size), contents: image)

        beginDraggingSession(with: [dragItem], event: event, source: self)
        return true
    }

    /// 跟随光标的小胶囊。
    private static func previewImage(count: Int) -> NSImage {
        let text = count > 1 ? "\(count) 封邮件" : "1 封邮件"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.controlTextColor,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: textSize.width + 28, height: textSize.height + 10)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        (text as NSString).draw(at: NSPoint(x: 14, y: 5), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        MainActor.assumeIsolated { DragMonitor.shared.end() }
    }
}
