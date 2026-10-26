#if os(macOS)
import SwiftUI
import WebKit
import OMPCore
import OMPDesign

/// The side panel's Browser tab (official `thread.sidePanel` Browser page):
/// real web views behind a tab strip and an address field. No fake pages and
/// no bundled content — each tab loads whatever URL is typed, and says so when
/// a load fails.
///
/// The tab list lives in the model (`browserTabs`) so debug actions drive it;
/// the web views live here, one per tab, so switching tabs neither reloads
/// the page nor loses its scroll position.
struct BrowserPane: View {
    @Environment(ChatAppModel.self) private var model
    @State private var pages = BrowserPages()
    /// The address field. Follows the selected tab's address unless it is
    /// being edited.
    @State private var text = ""
    @FocusState private var addressFocused: Bool
    @State private var hoveredTabID: UUID?
    /// Tab being renamed in place (重命名…) and the name being typed.
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    /// Which tab's name field has focus; per tab, so starting a second rename
    /// is not mistaken for clicking away from the first.
    @FocusState private var renameFocus: UUID?

    private var tabs: BrowserTabList { model.browserTabs }

    var body: some View {
        let selected = tabs.selected
        let current = livePage(for: selected)
        VStack(spacing: 0) {
            tabStrip
            Divider()
            addressBar(current)
            Divider()
            ZStack {
                BrowserWebHost(webView: current.webView)
                if let failure = current.failure {
                    failureView(failure)
                }
            }
        }
        .onAppear { text = selected.url }
        .onChange(of: tabs.selectedID) { _, _ in text = tabs.selected.url }
        // Redirects and link clicks move the address; typing is left alone.
        .onChange(of: selected.url) { _, url in
            if !addressFocused { text = url }
        }
        .onChange(of: tabs.tabs.map(\.id)) { _, ids in pages.keep(only: Set(ids)) }
        // A navigation made through the model (address bar or debug action)
        // reaches the web view of whichever tab it targets.
        .onChange(of: tabs.tabs.map(\.url)) { _, _ in pages.follow(tabs.tabs) }
        // Clicking away from the name field keeps what was typed.
        .onChange(of: renameFocus) { lost, _ in
            if let lost, lost == renamingTabID { finishRename() }
        }
    }

    // MARK: Tab strip

    private var tabStrip: some View {
        HStack(spacing: 4) {
            GeometryReader { proxy in
                let width = Self.tabWidth(available: proxy.size.width - 12, count: tabs.tabs.count)
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Self.tabSpacing) {
                            ForEach(tabs.tabs) { tab in
                                tabItem(tab)
                                    .frame(width: width)
                            }
                        }
                        .padding(.horizontal, 6)
                        .frame(maxHeight: .infinity)
                    }
                    .onChange(of: tabs.selectedID) { _, id in
                        withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("panel.browser.tabStrip")

            Button {
                model.openBrowserTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新建标签页")
            .accessibilityIdentifier("panel.browser.newTab")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
    }

    private static let tabSpacing: CGFloat = 2

    /// Tabs share the strip the way a browser's do: as wide as fits, between
    /// a readable minimum and a cap. Past the minimum the strip scrolls.
    private static func tabWidth(available: CGFloat, count: Int) -> CGFloat {
        let count = max(count, 1)
        let share = (available - tabSpacing * CGFloat(count - 1)) / CGFloat(count)
        return min(150, max(76, share))
    }

    private func tabItem(_ tab: BrowserTab) -> some View {
        let isSelected = tab.id == tabs.selectedID
        let isHovered = hoveredTabID == tab.id
        let showsClose = isSelected || isHovered
        return HStack(spacing: 2) {
            if renamingTabID == tab.id {
                TextField(tab.displayTitle, text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($renameFocus, equals: tab.id)
                    .onSubmit(finishRename)
                    .onExitCommand { renamingTabID = nil }
                    // Focus once the field exists, so typing goes straight in.
                    .onAppear { DispatchQueue.main.async { renameFocus = tab.id } }
                    .accessibilityIdentifier("panel.browser.renameField")
            } else {
                Button {
                    model.selectBrowserTab(tab.id)
                } label: {
                    Text(tab.displayTitle)
                        .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.ompText : Color.ompTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.displayTitle)
                .accessibilityIdentifier("panel.browser.tab")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }

            // Shown on the selected tab and under the pointer, like a
            // browser's; it keeps its slot so titles do not jump on hover.
            Button {
                model.closeBrowserTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.ompTextSecondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .accessibilityHidden(!showsClose)
            .help("关闭标签页")
            .accessibilityIdentifier("panel.browser.tab.close")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.ompFill : isHovered ? Color.ompHover : Color.clear)
        }
        .onHover { inside in
            if inside {
                hoveredTabID = tab.id
            } else if hoveredTabID == tab.id {
                hoveredTabID = nil
            }
        }
        .contextMenu {
            Button("在右侧新建标签页") { model.openBrowserTab(rightOf: tab.id) }
            Button("复制标签页") { model.duplicateBrowserTab(tab.id) }
            Button("重命名…") { beginRename(tab) }
            Divider()
            Button("关闭标签页") { model.closeBrowserTab(tab.id) }
        }
    }

    private func beginRename(_ tab: BrowserTab) {
        // A rename already open keeps what was typed.
        finishRename()
        renameText = tab.displayTitle
        renamingTabID = tab.id
    }

    /// Return or clicking away keeps the name; Escape drops it.
    private func finishRename() {
        guard let id = renamingTabID else { return }
        renamingTabID = nil
        guard let tab = tabs.tab(id) else { return }
        // Confirming the name unchanged keeps the tab following its page; a
        // blank name clears the custom title.
        if renameText.trimmingCharacters(in: .whitespacesAndNewlines) != tab.displayTitle {
            model.renameBrowserTab(id, to: renameText)
        }
    }

    // MARK: Address bar

    private func addressBar(_ page: BrowserPage) -> some View {
        HStack(spacing: 6) {
            Button {
                commitAddress(page)
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
                .focused($addressFocused)
                .onSubmit { commitAddress(page) }
                .accessibilityIdentifier("panel.browser.address")
            if page.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)

            // Reload / copy / open-in-browser target the page the selected
            // tab's web view holds, not whatever the field is mid-typing.
            Button {
                page.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            .buttonStyle(.plain)
            .disabled(page.loadedURL == nil && page.failure == nil)
            .help("重新加载")
            .accessibilityIdentifier("panel.browser.reload")

            Button {
                copy(page.loadedURL)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            .buttonStyle(.plain)
            .disabled(page.loadedURL == nil)
            .help("复制网址")
            .accessibilityIdentifier("panel.browser.copyURL")

            Button {
                openInDefaultBrowser(page.loadedURL)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            .buttonStyle(.plain)
            .disabled(page.loadedURL == nil)
            .help("在默认浏览器中打开")
            .accessibilityIdentifier("panel.browser.openExternal")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private func failureView(_ failure: String) -> some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Covers whatever page the web view still holds from before.
        .background(Color.ompCanvas)
    }

    /// Sends the field to the selected tab. Return on the address already
    /// shown loads it afresh, as a browser does.
    private func commitAddress(_ page: BrowserPage) {
        let tab = tabs.selected
        let url = BrowserTarget.resolve(text, fallback: tab.url)
        text = url
        addressFocused = false
        if url == tab.url {
            page.load(url)
        } else {
            model.navigateBrowserTab(tab.id, to: url)
        }
    }

    private func livePage(for tab: BrowserTab) -> BrowserPage {
        let model = self.model
        return pages.page(for: tab) { id, url, title in
            model.updateBrowserPage(id, url: url, title: title)
        }
    }

    private func copy(_ url: String?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Hands the page to the user's default browser via NSWorkspace.
    private func openInDefaultBrowser(_ url: String?) {
        guard let url, let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }
}

/// The live pages behind the tab strip, keyed by tab id. A tab's page is made
/// when the tab is first shown and released when the tab closes. The whole set
/// goes when the pane does; the tab list lives on in the model, and each tab
/// loads its address again when next shown.
@MainActor
private final class BrowserPages {
    /// One session for every tab — shared cookies, so a duplicated tab stays
    /// signed in — with nothing written to disk.
    private lazy var dataStore = WKWebsiteDataStore.nonPersistent()
    private var pages: [UUID: BrowserPage] = [:]

    func page(for tab: BrowserTab, report: @escaping (UUID, String, String) -> Void) -> BrowserPage {
        if let page = pages[tab.id] { return page }
        let id = tab.id
        let page = BrowserPage(url: tab.url, dataStore: dataStore) { url, title in
            report(id, url, title)
        }
        pages[id] = page
        return page
    }

    /// Points each live page at its tab's address.
    func follow(_ tabs: [BrowserTab]) {
        for tab in tabs {
            pages[tab.id]?.follow(tab.url)
        }
    }

    /// Releases the pages of tabs that are gone.
    func keep(only ids: Set<UUID>) {
        for (id, page) in pages where !ids.contains(id) {
            page.close()
            pages[id] = nil
        }
    }
}

/// One tab's web view and its load state.
@MainActor
@Observable
private final class BrowserPage {
    let webView: WKWebView
    private(set) var isLoading = false
    /// Why the last load failed; cleared when a new one starts or commits.
    private(set) var failure: String?
    /// Address of the page the web view holds; nil until a load committed.
    private(set) var loadedURL: String?

    /// The address this page last loaded or reported, so the tab list echoing
    /// a report back does not load it a second time.
    @ObservationIgnored private var shownURL: String
    private let report: (_ url: String, _ title: String) -> Void
    @ObservationIgnored private var navigator: Navigator?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(url: String, dataStore: WKWebsiteDataStore, report: @escaping (_ url: String, _ title: String) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        shownURL = url
        self.report = report

        // The web view holds its delegate weakly; the page keeps it alive.
        let navigator = Navigator()
        navigator.page = self
        webView.navigationDelegate = navigator
        self.navigator = navigator
        observations = [
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            // Pages retitle themselves after load (and single-page apps on
            // every route change), so the strip follows the title itself.
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publish() }
            },
        ]
        load(url)
    }

    /// Loads an address afresh.
    func load(_ url: String) {
        shownURL = url
        guard let target = URL(string: url) else {
            failure = "地址无效"
            return
        }
        failure = nil
        webView.load(URLRequest(url: target))
    }

    /// Loads the tab's address unless this page already loaded or reported it.
    func follow(_ url: String) {
        guard url != shownURL else { return }
        load(url)
    }

    /// 重新加载: retries an address that failed, otherwise reloads the page shown.
    func reload() {
        if failure != nil || webView.url == nil {
            load(shownURL)
        } else {
            webView.reload()
        }
    }

    /// Stops the page and detaches it; its tab is gone.
    func close() {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    /// Hands what the web view now shows back to the tab list.
    private func publish() {
        guard let url = webView.url?.absoluteString else { return }
        loadedURL = url
        shownURL = url
        report(url, webView.title ?? "")
    }

    private func didFail(_ error: Error) {
        // A load replaced by a newer one reports itself cancelled; the newer
        // one is still running, so that is not a failure.
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        failure = error.localizedDescription
    }

    private final class Navigator: NSObject, WKNavigationDelegate {
        weak var page: BrowserPage?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            page?.failure = nil
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            page?.failure = nil
            page?.publish()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            page?.publish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            page?.didFail(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            page?.didFail(error)
        }
    }
}

/// Shows one tab's web view. A container rather than the web view itself, so
/// switching tabs swaps which live web view sits inside it and SwiftUI never
/// tears one down.
private struct BrowserWebHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

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

#endif
