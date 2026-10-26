import XCTest
@testable import OMPCore

/// The side panel browser's tab rules: where new tabs land, which tab is
/// selected after a close, and what the strip calls each tab.
final class BrowserTabListTests: XCTestCase {
    private let home = "https://example.com"

    /// Three tabs a, b, c with `selected` on screen.
    private func threeTabs(selecting selected: Int) -> (BrowserTabList, [UUID]) {
        var list = BrowserTabList(homeURL: home)
        let a = list.selectedID
        let b = list.open(url: "https://b.test")
        let c = list.open(url: "https://c.test")
        let ids = [a, b, c]
        list.select(ids[selected])
        return (list, ids)
    }

    func testStartsWithOneSelectedHomeTab() {
        let list = BrowserTabList(homeURL: home)
        XCTAssertEqual(list.tabs.count, 1)
        XCTAssertEqual(list.selected.url, home)
        XCTAssertEqual(list.selectedID, list.tabs[0].id)
    }

    func testOpenRightOfSelectedInsertsNextToItAndSelects() {
        var (list, ids) = threeTabs(selecting: 0)
        let new = list.open(url: "https://new.test", rightOf: list.selectedID)
        XCTAssertEqual(list.tabs.map(\.id), [ids[0], new, ids[1], ids[2]])
        XCTAssertEqual(list.selectedID, new)
        XCTAssertEqual(list.selected.url, "https://new.test")
    }

    func testOpenWithoutAnchorAppendsAtEndAtHomePage() {
        var (list, ids) = threeTabs(selecting: 0)
        let new = list.open()
        XCTAssertEqual(list.tabs.map(\.id), ids + [new])
        XCTAssertEqual(list.selectedID, new)
        XCTAssertEqual(list.selected.url, home)
    }

    func testOpenRightOfUnknownTabAppendsAtEnd() {
        var (list, ids) = threeTabs(selecting: 1)
        let new = list.open(rightOf: UUID())
        XCTAssertEqual(list.tabs.map(\.id), ids + [new])
    }

    func testClosingSelectedTabSelectsRightNeighbour() {
        var (list, ids) = threeTabs(selecting: 1)
        list.close(ids[1])
        XCTAssertEqual(list.tabs.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(list.selectedID, ids[2])
    }

    func testClosingSelectedLastTabSelectsLeftNeighbour() {
        var (list, ids) = threeTabs(selecting: 2)
        list.close(ids[2])
        XCTAssertEqual(list.tabs.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(list.selectedID, ids[1])
    }

    func testClosingAnotherTabKeepsSelection() {
        var (list, ids) = threeTabs(selecting: 2)
        list.close(ids[0])
        XCTAssertEqual(list.tabs.map(\.id), [ids[1], ids[2]])
        XCTAssertEqual(list.selectedID, ids[2])
    }

    func testClosingOnlyTabLeavesOneFreshHomeTab() {
        var list = BrowserTabList(homeURL: home)
        let only = list.selectedID
        list.navigate(only, to: "https://elsewhere.test")
        list.rename(only, to: "Mine")
        list.close(only)
        XCTAssertEqual(list.tabs.count, 1)
        XCTAssertNotEqual(list.selectedID, only)
        XCTAssertEqual(list.selectedID, list.tabs[0].id)
        XCTAssertEqual(list.selected.url, home)
        XCTAssertNil(list.selected.customTitle)
        XCTAssertEqual(list.selected.title, "")
    }

    func testClosingUnknownTabChangesNothing() {
        var (list, _) = threeTabs(selecting: 1)
        let before = list
        list.close(UUID())
        XCTAssertEqual(list, before)
    }

    func testDuplicateInsertsCopyRightOfSourceAndSelectsIt() {
        var (list, ids) = threeTabs(selecting: 2)
        list.updatePage(ids[0], url: "https://a.test/page", title: "A page")
        list.rename(ids[0], to: "Pinned")
        let copy = list.duplicate(ids[0])
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy, ids[0])
        XCTAssertEqual(list.tabs.map(\.id), [ids[0], copy!, ids[1], ids[2]])
        XCTAssertEqual(list.selectedID, copy)
        XCTAssertEqual(list.selected.url, "https://a.test/page")
        XCTAssertEqual(list.selected.title, "A page")
        XCTAssertEqual(list.selected.customTitle, "Pinned")
    }

    func testDuplicateUnknownTabReturnsNilAndChangesNothing() {
        var (list, _) = threeTabs(selecting: 0)
        let before = list
        XCTAssertNil(list.duplicate(UUID()))
        XCTAssertEqual(list, before)
    }

    func testRenameTrimsAndBlankClearsCustomTitle() {
        var list = BrowserTabList(homeURL: home)
        let id = list.selectedID
        list.updatePage(id, url: home, title: "Example Domain")
        list.rename(id, to: "  文档  ")
        XCTAssertEqual(list.selected.customTitle, "文档")
        XCTAssertEqual(list.selected.displayTitle, "文档")
        list.rename(id, to: "   ")
        XCTAssertNil(list.selected.customTitle)
        XCTAssertEqual(list.selected.displayTitle, "Example Domain")
    }

    func testDisplayTitlePrecedence() {
        var tab = BrowserTab(url: "https://docs.example.org/guide?x=1", title: "Guide", customTitle: "Mine")
        XCTAssertEqual(tab.displayTitle, "Mine")
        tab.customTitle = nil
        XCTAssertEqual(tab.displayTitle, "Guide")
        tab.title = "  "
        XCTAssertEqual(tab.displayTitle, "docs.example.org")
        tab.url = "not a url"
        XCTAssertEqual(tab.displayTitle, "新标签页")
        tab.url = ""
        XCTAssertEqual(tab.displayTitle, "新标签页")
    }

    func testNavigateTouchesOnlyItsTabAndDropsStaleTitle() {
        var (list, ids) = threeTabs(selecting: 0)
        list.updatePage(ids[0], url: "https://a.test", title: "A")
        list.updatePage(ids[1], url: "https://b.test", title: "B")
        let others = list.tabs.filter { $0.id != ids[0] }
        list.navigate(ids[0], to: "https://moved.test")
        XCTAssertEqual(list.tab(ids[0])?.url, "https://moved.test")
        XCTAssertEqual(list.tab(ids[0])?.title, "")
        XCTAssertEqual(list.tab(ids[0])?.displayTitle, "moved.test")
        XCTAssertEqual(list.tabs.filter { $0.id != ids[0] }, others)
        XCTAssertEqual(list.selectedID, ids[0])
    }

    func testNavigateToSameAddressKeepsTitle() {
        var list = BrowserTabList(homeURL: home)
        let id = list.selectedID
        list.updatePage(id, url: home, title: "Example Domain")
        list.navigate(id, to: home)
        XCTAssertEqual(list.selected.title, "Example Domain")
    }

    func testUpdatePageTouchesOnlyItsTabAndKeepsSelection() {
        var (list, ids) = threeTabs(selecting: 2)
        let others = list.tabs.filter { $0.id != ids[1] }
        list.updatePage(ids[1], url: "https://b.test/final", title: "Final")
        XCTAssertEqual(list.tab(ids[1])?.url, "https://b.test/final")
        XCTAssertEqual(list.tab(ids[1])?.title, "Final")
        XCTAssertEqual(list.tabs.filter { $0.id != ids[1] }, others)
        XCTAssertEqual(list.selectedID, ids[2])
    }

    func testSelectUnknownTabKeepsSelection() {
        var (list, ids) = threeTabs(selecting: 1)
        list.select(UUID())
        XCTAssertEqual(list.selectedID, ids[1])
    }
}
