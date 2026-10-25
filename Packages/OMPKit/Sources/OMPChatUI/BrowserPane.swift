#if os(macOS)
import SwiftUI
import WebKit
import OMPDesign

/// The side panel's Browser tab (official `thread.sidePanel` Browser page): a
/// real web view with an address field. No fake pages and no bundled content —
/// it loads whatever URL is typed, and says so when a load fails.
struct BrowserPane: View {
    /// Where the tab starts. A search engine when the input is not a URL.
    @State private var text = "https://example.com"
    @State private var committed = "https://example.com"
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    committed = target(text)
                    text = committed
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .buttonStyle(.plain)
                .help("打开")
                TextField("输入网址或搜索词", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        committed = target(text)
                        text = committed
                    }
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)

            Divider()

            ZStack {
                BrowserWebView(url: committed, isLoading: $isLoading, failure: $failure)
                if let failure {
                    VStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.ompTextTertiary)
                        Text("打不开这个页面")
                            .font(.system(size: 13, weight: .medium))
                        Text(failure)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.ompTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
        }
    }

    private func target(_ raw: String) -> String {
        BrowserTarget.resolve(raw, fallback: committed)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let url: String
    @Binding var isLoading: Bool
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        load(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Reload only when the committed address really changed, so typing does
        // not reload on every keystroke.
        if webView.url?.absoluteString != url, webView.isLoading == false {
            load(webView)
        }
    }

    private func load(_ webView: WKWebView) {
        guard let target = URL(string: url) else {
            failure = "地址无效"
            return
        }
        failure = nil
        isLoading = true
        webView.load(URLRequest(url: target))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BrowserWebView

        init(_ parent: BrowserWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.failure = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.failure = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.failure = error.localizedDescription
        }
    }
}
#endif

/// Turns what the user typed into a URL.
///
/// An explicit `http://` is kept — rewriting it to https broke every local
/// address (the relay's own `/v1/health`, for one). Bare `host:port`,
/// `localhost` and `127.0.0.1` get `http://` for the same reason; other bare
/// hosts get https. Anything with a space is treated as a search.
enum BrowserTarget {
    static func resolve(_ raw: String, fallback: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fallback }
        if text.contains("://") { return text }
        let firstToken = text.split(separator: "/").first.map(String.init) ?? text
        let host = firstToken.split(separator: ":").first.map(String.init) ?? firstToken
        let looksLikeHost = !firstToken.contains(" ")
            && (host == "localhost" || host == "127.0.0.1" || host.contains("."))
        guard looksLikeHost else {
            let escaped = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            return "https://www.baidu.com/s?wd=\(escaped)"
        }
        let isLocal = host == "localhost" || host == "127.0.0.1"
            || firstToken.contains(":") && !firstToken.hasSuffix(":443")
        return (isLocal ? "http://" : "https://") + text
    }
}
