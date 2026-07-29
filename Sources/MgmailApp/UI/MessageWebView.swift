import SwiftUI
import WebKit

/// 编译并缓存「阻止远程内容」的规则列表（仿 Mail 的默认拦截跟踪像素）。
/// 只拦截 http(s) 资源，保留 data: 内联图片。
actor RemoteContentBlocker {
    static let shared = RemoteContentBlocker()
    private var cached: WKContentRuleList?

    private let ruleJSON = """
    [{"trigger":{"url-filter":"^https?://","resource-type":["image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}}]
    """

    func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        let store = WKContentRuleListStore.default()
        let json = ruleJSON
        let list: WKContentRuleList? = await withCheckedContinuation { cont in
            store?.compileContentRuleList(forIdentifier: "block-remote", encodedContentRuleList: json) { list, _ in
                cont.resume(returning: list)
            }
        }
        cached = list
        return list
    }
}

/// 用 WKWebView 渲染邮件 HTML 正文，自适应高度，默认拦截远程内容。
struct MessageWebView: NSViewRepresentable {
    let html: String
    let blockRemote: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MessageWebView
        var lastHTML: String?
        var lastBlockRemote: Bool?

        init(_ parent: MessageWebView) { self.parent = parent }

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
            webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                if let h = result as? CGFloat {
                    Task { @MainActor in self.parent.height = max(h, 40) }
                }
            }
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
            </style></head><body>\(body)</body></html>
            """
        }
    }
}
