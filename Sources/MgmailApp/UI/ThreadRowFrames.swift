import SwiftUI

/// 中栏各行此刻在窗口里的位置。
///
/// 多选叠加卡片靠它算「从哪儿飞来、飞回哪儿去」——起点和终点就是那封邮件
/// 在列表里的那一行。
///
/// 故意不做成 `ObservableObject`：行位置滚一下就变，做成可观察的会让右栏
/// 跟着无谓地重画。位置只在卡片起飞、降落那一刻各读一次，普通引用类型就够。
@MainActor
final class ThreadRowFrames {
    static let shared = ThreadRowFrames()

    private var frames: [SelectedThread: CGRect] = [:]

    func record(_ rect: CGRect, for key: SelectedThread) { frames[key] = rect }

    func forget(_ key: SelectedThread) { frames.removeValue(forKey: key) }

    /// 行滚出可视区域后就没有位置了，此时返回 nil，卡片退化成从侧边斜飞。
    func frame(for key: SelectedThread) -> CGRect? { frames[key] }
}

/// 贴在列表行背景上，把该行的窗口坐标登记进 `ThreadRowFrames`。
///
/// 只吃一个可比较的值、不带任何闭包：行视图的入参一旦混进闭包，
/// SwiftUI 每改一次选中就会重建整行并重新注册拖放，触发 NSTableView 重入。
struct ThreadRowFrameReporter: View {
    let key: SelectedThread

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onAppear { ThreadRowFrames.shared.record(frame, for: key) }
                .onChange(of: frame) { _, new in ThreadRowFrames.shared.record(new, for: key) }
                .onDisappear { ThreadRowFrames.shared.forget(key) }
        }
    }
}
