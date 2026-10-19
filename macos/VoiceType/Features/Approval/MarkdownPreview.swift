import SwiftUI
import WebKit

/// The Preview tab: the HTML from `OKMarkdownHTML.document` in a `WKWebView`
/// with JavaScript off. Only the load of `html` itself navigates; a clicked
/// link (or anything else) is cancelled, so nothing opens.
struct MarkdownPreview: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        context.coordinator.allowsNextLoad = true
        webView.loadHTMLString(html, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        /// Set right before `loadHTMLString`; the first main-frame navigation
        /// after it is that load.
        var allowsNextLoad = false

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if allowsNextLoad, navigationAction.navigationType == .other, navigationAction.targetFrame?.isMainFrame == true {
                allowsNextLoad = false
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
