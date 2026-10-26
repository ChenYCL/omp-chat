import Foundation

/// One tab of the side panel's 浏览器 (Codex `thread.sidePanel` browser tabs).
public struct BrowserTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The address the tab is on: what the address bar committed, then
    /// whatever the web view finally landed on (redirects included).
    public var url: String
    /// The title the loaded page reports; empty until a page reports one.
    public var title: String
    /// The name given with 重命名…; nil follows the page.
    public var customTitle: String?

    public init(id: UUID = UUID(), url: String, title: String = "", customTitle: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.customTitle = customTitle
    }

    /// What the tab strip shows: the custom name, else the page's title, else
    /// the address's host, else 新标签页.
    public var displayTitle: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        let pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageTitle.isEmpty { return pageTitle }
        if let host = URLComponents(string: url)?.host, !host.isEmpty { return host }
        return "新标签页"
    }
}

/// The side panel browser's tabs and which one is on screen.
///
/// Invariants: there is always at least one tab, and `selectedID` always
/// names one of them. Operations on an id that is not in the list do
/// nothing, so a stale id (a tab closed a moment ago) cannot corrupt it.
public struct BrowserTabList: Equatable, Sendable {
    /// Where every new tab starts, including the fresh tab that replaces the
    /// last one closed.
    public let homeURL: String
    public private(set) var tabs: [BrowserTab]
    public private(set) var selectedID: UUID

    public init(homeURL: String) {
        let first = BrowserTab(url: homeURL)
        self.homeURL = homeURL
        tabs = [first]
        selectedID = first.id
    }

    /// The tab on screen.
    public var selected: BrowserTab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    public func tab(_ id: UUID) -> BrowserTab? {
        tabs.first { $0.id == id }
    }

    /// Opens a tab right of `id` — at the end when `id` is nil or unknown —
    /// and selects it. A nil `url` opens the home page.
    @discardableResult
    public mutating func open(url: String? = nil, rightOf id: UUID? = nil) -> UUID {
        let tab = BrowserTab(url: url ?? homeURL)
        if let id, let index = index(of: id) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
        return tab.id
    }

    /// Closes a tab. Closing the selected one selects its right neighbour,
    /// else its left one; closing the last tab leaves one fresh tab at the
    /// home page, never an empty strip.
    public mutating func close(_ id: UUID) {
        guard let index = index(of: id) else { return }
        tabs.remove(at: index)
        guard !tabs.isEmpty else {
            let fresh = BrowserTab(url: homeURL)
            tabs = [fresh]
            selectedID = fresh.id
            return
        }
        guard selectedID == id else { return }
        // The right neighbour now sits at `index`; past the end, take the left.
        selectedID = tabs[min(index, tabs.count - 1)].id
    }

    /// Inserts a copy of a tab (address, title and custom name) right of it
    /// and selects the copy. Returns the copy's id, nil for an unknown tab.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> UUID? {
        guard let index = index(of: id) else { return nil }
        let source = tabs[index]
        let copy = BrowserTab(url: source.url, title: source.title, customTitle: source.customTitle)
        tabs.insert(copy, at: index + 1)
        selectedID = copy.id
        return copy.id
    }

    /// Names a tab. A blank name clears the custom title, so the tab follows
    /// its page again.
    public mutating func rename(_ id: UUID, to title: String) {
        guard let index = index(of: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    }

    public mutating func select(_ id: UUID) {
        guard index(of: id) != nil else { return }
        selectedID = id
    }

    /// Points a tab at a new address. The old page's title is dropped so the
    /// strip does not keep naming a page the tab no longer shows; the new page
    /// reports its own through `updatePage`.
    public mutating func navigate(_ id: UUID, to url: String) {
        guard let index = index(of: id), tabs[index].url != url else { return }
        tabs[index].url = url
        tabs[index].title = ""
    }

    /// Records what the tab's web view reports: the address it ended up on and
    /// the page's title.
    public mutating func updatePage(_ id: UUID, url: String, title: String) {
        guard let index = index(of: id) else { return }
        tabs[index].url = url
        tabs[index].title = title
    }

    private func index(of id: UUID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }
}
