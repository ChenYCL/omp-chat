#if os(macOS)
import Foundation
import OMPCore

/// Turns a `npx` / `uvx` server into something the sandboxed app can start:
/// the package is installed once under `root` and run through its interpreter.
/// `MCPPackageLaunch` explains why the launchers themselves cannot be used.
actor MCPPackagePreparer {
    struct Outcome: Sendable {
        var exitCode: Int32
        var output: String
    }

    /// Runs `argv` (`argv[0]` is an absolute path) with the app's child
    /// environment and returns its exit code and combined output.
    typealias Runner = @Sendable (_ argv: [String], _ timeout: Double) async -> Outcome

    enum Result: Equatable, Sendable {
        /// Not a package launcher shape, or its script is not one `node` can
        /// run: start it as configured.
        case unchanged
        case launch(executable: String, arguments: [String])
        case needsRuntime(MCPRuntime)
        case failure(reason: String, log: [String])
    }

    static let installTimeout: Double = 300

    private let root: URL
    private let run: Runner
    /// One install per package folder at a time; later callers wait for it.
    private var installing: [String: Task<Installed, Never>] = [:]

    private enum Installed: Equatable, Sendable {
        case nodeScript(String)
        case otherScript
        case entry(module: String, attribute: String)
        case failure(reason: String, log: [String])
    }

    init(root: URL, run: @escaping Runner) {
        self.root = root
        self.run = run
    }

    func prepare(_ plan: MCPPackageLaunch.Plan, path: String, home: String) async -> Result {
        switch plan {
        case .direct:
            return .unchanged
        case .npm(let spec, let rest):
            guard let node = MCPLaunchPlanner.locate("node", path: path, home: home),
                  let npm = MCPLaunchPlanner.locate("npm", path: path, home: home) else {
                return .needsRuntime(.node)
            }
            switch await once(spec.directoryName, { await self.installNpm(spec, npm: npm) }) {
            case .nodeScript(let script): return .launch(executable: node, arguments: [script] + rest)
            case .failure(let reason, let log): return .failure(reason: reason, log: log)
            case .otherScript, .entry: return .unchanged
            }
        case .uv(let spec, let rest):
            guard let uvx = MCPLaunchPlanner.locate("uvx", path: path, home: home) else {
                return .needsRuntime(.uv)
            }
            switch await once(spec.directoryName, { await self.resolveUV(spec, uvx: uvx) }) {
            case .entry(let module, let attribute):
                guard let code = MCPPackageLaunch.uvRunCode(module: module, attribute: attribute) else {
                    return .failure(reason: "\(spec.name) 的入口「\(module):\(attribute)」不合法", log: [])
                }
                return .launch(executable: uvx, arguments: ["--from", spec.spec, "python", "-c", code] + rest)
            case .failure(let reason, let log): return .failure(reason: reason, log: log)
            case .nodeScript, .otherScript: return .unchanged
            }
        }
    }

    private func once(_ key: String, _ work: @escaping @Sendable () async -> Installed) async -> Installed {
        if let running = installing[key] { return await running.value }
        let task = Task { await work() }
        installing[key] = task
        let result = await task.value
        installing[key] = nil
        return result
    }

    // MARK: npm

    private func installNpm(_ spec: MCPPackageLaunch.NpmSpec, npm: String) async -> Installed {
        let directory = root.appendingPathComponent(spec.directoryName, isDirectory: true)
        let package = directory.appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(spec.name, isDirectory: true)
        let manifest = package.appendingPathComponent("package.json")

        if !isInstalled(manifest, exactVersion: spec.exactVersion) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let outcome = await run(
                [npm, "install", "--prefix", directory.path, "--no-audit", "--no-fund", "--loglevel=error", spec.spec],
                Self.installTimeout
            )
            guard outcome.exitCode == 0 else {
                return .failure(reason: "安装 \(spec.spec) 失败（npm 退出码 \(outcome.exitCode)）", log: Self.tail(outcome.output))
            }
        }
        guard let data = try? Data(contentsOf: manifest),
              let relative = MCPPackageLaunch.binScript(packageJSON: data, packageName: spec.name) else {
            return .failure(reason: "找不到 \(spec.name) 的启动入口：package.json 没有可用的 bin", log: [])
        }
        let script = package.appendingPathComponent(relative).standardizedFileURL
        guard script.path.hasPrefix(package.standardizedFileURL.path + "/"),
              let handle = try? FileHandle(forReadingFrom: script) else {
            return .failure(reason: "\(spec.name) 的入口文件「\(relative)」不存在", log: [])
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        return MCPPackageLaunch.isNodeScript(head: head, fileName: script.lastPathComponent)
            ? .nodeScript(script.path)
            : .otherScript
    }

    /// An install is reusable when its manifest exists and, for an exact
    /// version, says that version; tags and ranges are installed once.
    private func isInstalled(_ manifest: URL, exactVersion: String?) -> Bool {
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let exactVersion else { return true }
        return object["version"] as? String == exactVersion
    }

    // MARK: uv

    private func resolveUV(_ spec: MCPPackageLaunch.UVSpec, uvx: String) async -> Installed {
        // An exact pin cannot change its entry point, so it is read once.
        let cache = root.appendingPathComponent(spec.directoryName + ".entry")
        let pinned = spec.spec.contains("==")
        if pinned, let text = try? String(contentsOf: cache, encoding: .utf8),
           let entry = MCPPackageLaunch.uvEntry(fromProbeOutput: "OMPENTRY " + text) {
            return .entry(module: entry.module, attribute: entry.attribute)
        }
        guard let probe = MCPPackageLaunch.uvEntryProbe(scriptName: spec.name) else {
            return .failure(reason: "「\(spec.name)」不是合法的包名", log: [])
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outcome = await run([uvx, "--from", spec.spec, "python", "-c", probe], Self.installTimeout)
        guard outcome.exitCode == 0 else {
            return .failure(reason: "安装 \(spec.spec) 失败（uvx 退出码 \(outcome.exitCode)）", log: Self.tail(outcome.output))
        }
        guard let entry = MCPPackageLaunch.uvEntry(fromProbeOutput: outcome.output) else {
            return .failure(reason: "\(spec.spec) 没有名为「\(spec.name)」的命令行入口", log: Self.tail(outcome.output))
        }
        if pinned { try? "\(entry.module):\(entry.attribute)".write(to: cache, atomically: true, encoding: .utf8) }
        return .entry(module: entry.module, attribute: entry.attribute)
    }

    /// The last few non-empty lines, for the failure's log.
    private static func tail(_ output: String, lines: Int = 8) -> [String] {
        Array(output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.suffix(lines))
    }
}
#endif
