import XCTest
@testable import OMPCore
@testable import OMPChatUI

/// Installing from real local git repositories through the app's command
/// runner: the recorded commit must be the one installed, and a hostile URL
/// or subdirectory must never reach git as an option or climb out.
@MainActor
final class PluginGitInstallTests: XCTestCase {
    private var root: URL!
    private var store: PluginStore!

    override func setUpWithError() throws {
        guard GitBinary.resolve() != nil else { throw XCTSkip("no git") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-gitplugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PluginStore(root: root.appendingPathComponent("store"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(GitBinary.resolve()))
        process.arguments = args
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, _ path: String, in repo: URL) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A repository with its own identity, so commits never depend on the
    /// machine's global git config.
    private func makeRepo(_ files: [String: String]) throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["config", "user.email", "a@b"], in: repo)
        try git(["config", "user.name", "a"], in: repo)
        try git(["config", "commit.gpgsign", "false"], in: repo)
        for (path, text) in files { try write(text, path, in: repo) }
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    private func prepare(_ url: String, ref: String? = nil, subdirectory: String? = nil) async throws -> PluginInstallPlan {
        try await store.prepareInstall(gitURL: url, ref: ref, subdirectory: subdirectory, runner: ChatAppModel.pluginCommandRunner)
    }

    func testInstallRecordsTheClonedCommitAndDropsHistory() async throws {
        let repo = try makeRepo([
            ".codex-plugin/plugin.json": #"{"name": "remote-helper", "version": "2.0.0"}"#,
            "skills/hello/SKILL.md": "---\nname: hello\ndescription: Say hello.\n---\n",
        ])
        let head = try git(["rev-parse", "HEAD"], in: repo)

        let plan = try await prepare(repo.path)
        XCTAssertEqual(plan.source, .git(url: repo.path, ref: nil, subdirectory: nil, commit: head))
        XCTAssertEqual(plan.contents.skills.map(\.name), ["remote-helper:hello"])
        let installed = try store.commitInstall(plan)
        XCTAssertEqual(installed.manifest?.version, "2.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (installed.root as NSString).appendingPathComponent(".git")))
        XCTAssertEqual(PluginStore(root: store.root).plugin(id: "remote-helper")?.source, plan.source, "the source survives a relaunch")
    }

    func testRefAndSubdirectorySelectThePlugin() async throws {
        let repo = try makeRepo([
            "plugins/one/.codex-plugin/plugin.json": #"{"name": "one", "version": "1.0.0"}"#,
            "README.md": "marketplace",
        ])
        try git(["checkout", "-q", "-b", "next"], in: repo)
        try write(#"{"name": "one", "version": "1.1.0"}"#, "plugins/one/.codex-plugin/plugin.json", in: repo)
        try git(["commit", "-q", "-am", "bump"], in: repo)
        let next = try git(["rev-parse", "HEAD"], in: repo)
        try git(["checkout", "-q", "main"], in: repo)

        let plan = try await prepare("file://" + repo.path, ref: "next", subdirectory: "/plugins/one/")
        XCTAssertEqual(plan.manifest.version, "1.1.0")
        XCTAssertEqual(plan.source, .git(url: "file://" + repo.path, ref: "next", subdirectory: "plugins/one", commit: next))
        let installed = try store.commitInstall(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: (installed.root as NSString).appendingPathComponent("README.md")),
                       "only the subdirectory is installed")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("staging").path)) ?? [], [])
    }

    func testHostileInputNeverReachesGit() async throws {
        for url in ["-oProxyCommand=touch /tmp/pwned", "https://", "has space.git", "", "not a url"] {
            do {
                _ = try await prepare(url)
                XCTFail("accepted \(url)")
            } catch {
                XCTAssertEqual(error as? PluginStoreError, .badGitURL, url)
            }
        }
        do {
            _ = try await prepare("https://example.com/p.git", ref: "--upload-pack=evil")
            XCTFail("accepted an option as ref")
        } catch {
            XCTAssertEqual(error as? PluginStoreError, .badGitURL)
        }
        do {
            _ = try await prepare("https://example.com/p.git", subdirectory: "../../etc")
            XCTFail("accepted a climbing subdirectory")
        } catch {
            XCTAssertEqual(error as? PluginStoreError, .badSubdirectory)
        }
    }

    func testCloneFailureIsReportedAndCleanedUp() async throws {
        do {
            _ = try await prepare(root.appendingPathComponent("no-such-repo").path)
            XCTFail("cloned nothing")
        } catch let PluginStoreError.git(detail) {
            XCTAssertFalse(detail.isEmpty)
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("staging").path)) ?? [], [])

        let notAPlugin = try makeRepo(["README.md": "hi"])
        do {
            _ = try await prepare(notAPlugin.path)
            XCTFail("installed a repository without a manifest")
        } catch {
            XCTAssertEqual(error.localizedDescription, PluginManifest.ParseError.missing.localizedDescription)
        }
    }
}
