import XCTest
@testable import OMPCore

/// The header's Open-in button and 打开方式: which app gets what.
final class OpenInTargetTests: XCTestCase {
    private func target(_ id: String) throws -> OpenInTarget {
        try XCTUnwrap(OpenInTarget.catalog.first { $0.id == id })
    }

    func testTerminalsGetAFilesFolderNeverTheFileItself() throws {
        for id in ["terminal", "iterm2"] {
            let terminal = try target(id)
            XCTAssertEqual(terminal.action(for: "/w/repo/run.sh", isDirectory: false), .open("/w/repo"),
                           "\(id) 会把文件当脚本执行")
            XCTAssertEqual(terminal.action(for: "/w/repo", isDirectory: true), .open("/w/repo"))
            XCTAssertEqual(terminal.action(for: "/top.sh", isDirectory: false), .open("/"))
        }
    }

    func testFinderShowsAFolderAndSelectsAFile() throws {
        let finder = try target("finder")
        XCTAssertEqual(finder.action(for: "/w/repo", isDirectory: true), .showFolder("/w/repo"))
        XCTAssertEqual(finder.action(for: "/w/repo/a.swift", isDirectory: false), .reveal("/w/repo/a.swift"))
    }

    func testEditorsOpenThePathItself() throws {
        for id in ["vscode", "cursor", "windsurf", "zed", "xcode", "sublimeText", "nova"] {
            let editor = try target(id)
            XCTAssertEqual(editor.action(for: "/w/repo/a.swift", isDirectory: false), .open("/w/repo/a.swift"))
            XCTAssertEqual(editor.action(for: "/w/repo", isDirectory: true), .open("/w/repo"))
        }
    }

    func testPreferredIsTheLastUsedWhileInstalledElseTheFirst() throws {
        let installed = [try target("finder"), try target("vscode"), try target("xcode")]
        XCTAssertEqual(OpenInTarget.preferred(lastUsedID: "xcode", installed: installed)?.id, "xcode")
        XCTAssertEqual(OpenInTarget.preferred(lastUsedID: "cursor", installed: installed)?.id, "finder",
                       "上次用的应用卸载了就退回第一个")
        XCTAssertEqual(OpenInTarget.preferred(lastUsedID: "", installed: installed)?.id, "finder")
        XCTAssertNil(OpenInTarget.preferred(lastUsedID: "finder", installed: []))
    }

    func testLastUsedTargetSurvivesASettingsRoundTripAndOldDocumentsDecode() throws {
        var settings = AppSettings()
        settings.openInTargetID = "cursor"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.openInTargetID, "cursor")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).openInTargetID, "")
    }
}
