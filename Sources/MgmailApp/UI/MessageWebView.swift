import SwiftUI
import WebKit

/// 编译并缓存「阻止远程内容」的规则列表（仿 Mail 的默认拦截跟踪像素）。
/// 只拦截 http(s) 资源，保留 data: 内联图片。
///
/// 跟着 WebKit 待在主线程上：`WKContentRuleListStore` 整套都是主线程隔离的。
@MainActor
final class RemoteContentBlocker {
    static let shared = RemoteContentBlocker()

    /// 缓存的是「编译这件事」而不是编译结果。
    ///
    /// 缓存结果的话，切换邮件时几封正文同时来要规则，都会看到「还没有」而各编一遍——
    /// await 之间是可以被插进来的，`@MainActor` 挡不住这种重入。
    /// 存下任务就只会编译一次，后来的都在同一个任务上等。
    private var compilation: Task<WKContentRuleList?, Never>?

    private static let ruleJSON = """
    [{"trigger":{"url-filter":"^https?://","resource-type":["image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}}]
    """

    func ruleList() async -> WKContentRuleList? {
        if let compilation { return await compilation.value }
        let task = Task { @MainActor () -> WKContentRuleList? in
            guard let store = WKContentRuleListStore.default() else { return nil }
            return await withCheckedContinuation { cont in
                store.compileContentRuleList(forIdentifier: "block-remote",
                                             encodedContentRuleList: Self.ruleJSON) { list, _ in
                    cont.resume(returning: list)
                }
            }
        }
        compilation = task
        return await task.value
    }
}

/// WKWebView 子类：纵向滚轮事件不自己消费，转发给外层 SwiftUI ScrollView，
/// 这样在多封邮件的会话里滚动时是整体滚动，而不是只滚动鼠标下的那一封。
///
/// 横向的那一半得留下来自己滚。外层 ScrollView 只有纵轴，横向事件递出去就是石沉大海，
/// 而超出窗口宽度的正文（宽表格、大图、不折行的长串）本来就只有这一条路能看全。
final class PassthroughWebView: WKWebView {
    /// 正文这会儿有没有超出可视宽度，由页面脚本量出来告诉我们。
    ///
    /// 没超出就不该截胡横滑：那时候自己滚不动，事件却也到不了外层，
    /// 触控板上斜着滑一下会莫名其妙地卡住。
    var hasHorizontalOverflow = false

    /// 这一串滚动事件是不是自己留着横滚。
    ///
    /// 手势一开始就定下来，中途不改主意：滑动很少是正南正北的，逐个事件判断的话
    /// 一次滑动会在自己和外层之间来回跳，内容一顿一顿的。
    private var keepsGesture = false

    override func scrollWheel(with event: NSEvent) {
        // 触控板手势在 .began 那一下定方向，后续的 .changed 和惯性滑行都沿用；
        // 传统滚轮没有 phase，每个事件各自判断。
        if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            keepsGesture = wantsHorizontalScroll(event)
        }
        if keepsGesture {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    /// 这一下是不是冲着横向来的：正文确实横向溢出，且手势偏横——
    /// 或者按住了 shift，那是只有一个滚轮的鼠标表达「横着滚」的方式。
    private func wantsHorizontalScroll(_ event: NSEvent) -> Bool {
        guard hasHorizontalOverflow else { return false }
        if event.modifierFlags.contains(.shift) { return true }
        return abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
    }
}

/// 正文卡片的高度记忆与 WebKit 预热。
///
/// 切换邮件时每封正文都是一个新建的 WKWebView，而它要等 WebKit 渲染进程起来、
/// HTML 解析完、脚本回报高度之后才撑得开——在此之前卡片只有初始高度，
/// 用户看到的就是「标题已经换了，正文却空着」。这里从两头缩短那段空白：
/// 提前把渲染进程拉起来，并记住每封邮件量到过的高度，再打开时直接按那个高度铺开。
@MainActor
enum MessageBodyLayout {
    private static var heights: [String: CGFloat] = [:]
    /// 与 `heights` 同步维护的写入顺序，用来把它裁在上限之内。
    private static var order: [String] = []
    /// 记多少封的高度。这只是个开屏加速的提示值，记不住最多是正文先塌一下再撑开，
    /// 所以没必要为它无限占着内存——长期开着的窗口会一直往里加。
    private static let capacity = 400
    private static var warmup: WKWebView?

    static func height(for messageID: String) -> CGFloat {
        heights[messageID] ?? 40
    }

    static func remember(_ height: CGFloat, for messageID: String) {
        if heights.updateValue(height, forKey: messageID) == nil {
            order.append(messageID)
        }
        guard order.count > capacity else { return }
        let drop = order.count - capacity
        for old in order.prefix(drop) { heights.removeValue(forKey: old) }
        order.removeFirst(drop)
    }

    /// 提前起一个空 WebView，把 WebKit 的渲染进程拉起来，
    /// 第一封邮件的正文就不必等进程冷启动。
    static func warmUp() {
        guard warmup == nil else { return }
        let view = WKWebView(frame: .zero)
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
        warmup = view
    }
}

/// 用 WKWebView 渲染邮件 HTML 正文，自适应高度，默认拦截远程内容。
struct MessageWebView: NSViewRepresentable {
    let html: String
    let blockRemote: Bool
    /// 用来记住这封正文的高度，下次打开直接按它铺开。
    var messageID: String = ""
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 让页面能把内容高度变化（图片加载、布局变动）回传给宿主。
        config.userContentController.add(context.coordinator, name: "heightChanged")
        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // 透明背景，融入 SwiftUI
        context.coordinator.load(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // html 或 blockRemote 变化时重新加载
        if context.coordinator.lastHTML != html || context.coordinator.lastBlockRemote != blockRemote {
            context.coordinator.parent = self
            context.coordinator.load(in: webView)
        }
    }

    /// 视图销毁时移除脚本消息处理器，避免 userContentController 强引用 coordinator 泄漏。
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "heightChanged")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MessageWebView
        var lastHTML: String?
        var lastBlockRemote: Bool?

        init(_ parent: MessageWebView) { self.parent = parent }

        /// 收到页面回传的内容尺寸，同步更新宿主 frame，避免内部产生纵向溢出滚动；
        /// 横向溢没溢出则交给 web view，它据此决定横滑要不要留下自己滚。
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "heightChanged", let payload = message.body as? [String: Any],
                  let h = (payload["height"] as? NSNumber)?.doubleValue else { return }
            let overflowX = (payload["overflowX"] as? NSNumber)?.boolValue ?? false
            let webView = message.webView
            Task { @MainActor in
                (webView as? PassthroughWebView)?.hasHorizontalOverflow = overflowX
                self.apply(max(CGFloat(h), 40))
            }
        }

        @MainActor
        private func apply(_ height: CGFloat) {
            parent.height = height
            if !parent.messageID.isEmpty {
                MessageBodyLayout.remember(height, for: parent.messageID)
            }
        }

        func load(in webView: WKWebView) {
            lastHTML = parent.html
            lastBlockRemote = parent.blockRemote
            let html = parent.html
            let block = parent.blockRemote
            Task { @MainActor in
                webView.configuration.userContentController.removeAllContentRuleLists()
                if block, let list = await RemoteContentBlocker.shared.ruleList() {
                    webView.configuration.userContentController.add(list)
                }
                webView.loadHTMLString(Self.wrap(html), baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 关掉 WKWebView 内部滚动视图的弹性，配合精确高度，让内部无内容可滚，
            // 滚轮事件顺着响应链交给外层 ScrollView 整体滚动。
            disableInternalScrollElasticity(webView)
            // 脚本万一没跑起来（正文里有东西把它顶掉了），这儿自己量一次兜底。
            webView.evaluateJavaScript(Self.measureJS) { result, _ in
                guard let pair = result as? [Any],
                      let h = (pair.first as? NSNumber)?.doubleValue else { return }
                let overflowX = (pair.count > 1 ? pair[1] as? NSNumber : nil)?.boolValue ?? false
                Task { @MainActor in
                    (webView as? PassthroughWebView)?.hasHorizontalOverflow = overflowX
                    self.apply(max(CGFloat(h), 40))
                }
            }
        }

        /// 量正文尺寸：[内容高度, 是否横向溢出]。留 1px 余量，避开子像素带来的假溢出。
        private static let measureJS = """
        [document.body.scrollHeight,
         document.documentElement.scrollWidth > document.documentElement.clientWidth + 1]
        """

        /// 递归找到 WKWebView 内部的 NSScrollView 并关闭其弹性滚动。
        private func disableInternalScrollElasticity(_ view: NSView) {
            if let scrollView = view as? NSScrollView {
                scrollView.verticalScrollElasticity = .none
                scrollView.horizontalScrollElasticity = .none
            }
            view.subviews.forEach { disableInternalScrollElasticity($0) }
        }

        // 用户点击正文里的链接：不在内嵌 web view 里打开，交给系统浏览器（且仅普通导航）。
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        /// 包一层基础样式，保证中文字体与自适应宽度。
        static func wrap(_ body: String) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            :root { color-scheme: light dark; }
            html,body{margin:0;padding:0;background:transparent;}
            body{font-family:-apple-system,'PingFang SC',system-ui,sans-serif;font-size:14px;
                 line-height:1.5;color:canvastext;word-wrap:break-word;overflow-wrap:break-word;}
            img{max-width:100%;height:auto;}
            a{color:#0a84ff;}
            blockquote{border-left:3px solid #ccc;margin:0;padding-left:12px;color:#666;}
            pre{white-space:pre-wrap;word-wrap:break-word;}
            table{max-width:100%;}
            </style></head><body>\(body)
            <script>
            (function () {
              function report() {
                var doc = document.documentElement;
                window.webkit.messageHandlers.heightChanged.postMessage({
                  height: Math.ceil(document.body.scrollHeight),
                  // 留 1px 余量，避开子像素带来的假溢出
                  overflowX: doc.scrollWidth > doc.clientWidth + 1
                });
              }
              // 内容尺寸变化（图片加载、字体就绪、窗口宽度变动）时都重新上报。
              // 窗口变窄会让原本放得下的正文溢出，横滚要跟着开；变宽则反过来。
              if (window.ResizeObserver) {
                var ro = new ResizeObserver(report);
                ro.observe(document.body);          // 内容高度
                ro.observe(document.documentElement); // 可视宽度
              }
              window.addEventListener('load', report);
              Array.prototype.forEach.call(document.images, function (img) {
                if (!img.complete) { img.addEventListener('load', report); img.addEventListener('error', report); }
              });
              report();
            })();
            </script>
            </body></html>
            """
        }
    }
}
