import Foundation
import CryptoKit

/// One operating system a local environment script or action targets.
///
/// Raw values match the official TOML (`darwin` / `linux` / `win32`) and the
/// platform order the official writer emits overrides in.
public enum LocalEnvironmentPlatform: String, Codable, CaseIterable, Sendable, Hashable {
    case darwin
    case linux
    case win32

    /// The platform this process runs on.
    public static var current: LocalEnvironmentPlatform {
        #if os(macOS)
        .darwin
        #elseif os(Linux)
        .linux
        #else
        .darwin
        #endif
    }

    /// The name shown in the editor's platform picker.
    public var displayName: String {
        switch self {
        case .darwin: "macOS"
        case .linux: "Linux"
        case .win32: "Windows"
        }
    }
}

/// A setup or cleanup script with optional per-platform overrides.
///
/// An override that is absent, or present but empty, means "use the default" —
/// the official app treats an empty override exactly like a missing one.
public struct LocalEnvironmentScript: Codable, Hashable, Sendable {
    /// The script that runs when the platform has no override.
    public var script: String
    /// Per-platform replacements; an empty value behaves like an absent one.
    public var overrides: [LocalEnvironmentPlatform: String]

    public init(script: String = "", overrides: [LocalEnvironmentPlatform: String] = [:]) {
        self.script = script
        self.overrides = overrides
    }

    /// The script that actually runs on `platform`: the override when it is
    /// non-empty, otherwise the default. `nil` when both are empty, which is
    /// "nothing to run" rather than an error.
    public func resolved(for platform: LocalEnvironmentPlatform) -> String? {
        if let override = overrides[platform], !override.isEmpty { return override }
        return script.isEmpty ? nil : script
    }
}

/// One toolbar command declared by a local environment.
///
/// `icon` is the official raw value (`tool`, `run`, `test`, `debug`); `nil`
/// renders as the tool icon. `platform` is `nil` for an action offered on
/// every platform, or one of the three platform raw values.
public struct LocalEnvironmentAction: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var icon: String?
    public var command: String
    public var platform: String?

    public var id: String { "\(name)\u{0}\(command)\u{0}\(platform ?? "")" }

    public init(name: String, icon: String? = "tool", command: String, platform: String? = nil) {
        self.name = name
        self.icon = icon
        self.command = command
        self.platform = platform
    }

    /// Whether the header offers this action on `platform`.
    public func applies(to platform: LocalEnvironmentPlatform) -> Bool {
        guard let raw = self.platform else { return true }
        return LocalEnvironmentPlatform(rawValue: raw) == platform
    }
    /// The SF Symbol the header draws for an action with this icon value;
    /// unknown values fall back to the tool icon, as the official app does.
    public static func symbolName(for icon: String?) -> String {
        switch icon {
        case "run": "play.fill"
        case "test": "checkmark.circle"
        case "debug": "ladybug"
        default: "wrench.and.screwdriver"
        }
    }

    public var symbolName: String { Self.symbolName(for: icon) }

    /// The label for an icon value in the editor's picker.
    public static func iconLabel(_ icon: String) -> String {
        switch icon {
        case "run": "运行"
        case "test": "测试"
        case "debug": "调试"
        default: "工具"
        }
    }
}

/// A parsed local environment.
///
/// `cleanup` is `nil` when the file declares no cleanup at all; a cleanup
/// table with an empty script is kept, and skips at run time.
public struct LocalEnvironment: Codable, Hashable, Sendable {
    public var version: Int
    public var name: String
    public var setup: LocalEnvironmentScript
    public var cleanup: LocalEnvironmentScript?
    public var actions: [LocalEnvironmentAction]

    public init(
        version: Int = 1,
        name: String,
        setup: LocalEnvironmentScript = LocalEnvironmentScript(),
        cleanup: LocalEnvironmentScript? = nil,
        actions: [LocalEnvironmentAction] = []
    ) {
        self.version = version
        self.name = name
        self.setup = setup
        self.cleanup = cleanup
        self.actions = actions
    }

    /// The actions the header offers on `platform`, in file order.
    public func actions(for platform: LocalEnvironmentPlatform) -> [LocalEnvironmentAction] {
        actions.filter { $0.applies(to: platform) }
    }

    /// Problems that keep this environment from being saved. Empty means the
    /// file can be written. Messages match the official wording, in Chinese.
    public func validationErrors() -> [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("请输入环境名称")
        }
        if version < 1 {
            problems.append("version 必须是不小于 1 的整数")
        }
        for action in actions {
            let name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || command.isEmpty {
                problems.append("每个动作都要有名称和命令")
            }
            if let icon = action.icon,
               !["tool", "run", "test", "debug"].contains(icon) {
                problems.append("动作「\(name)」的图标无效")
            }
            if let platform = action.platform,
               LocalEnvironmentPlatform(rawValue: platform) == nil {
                problems.append("动作「\(name)」的平台无效")
            }
        }
        return problems
    }
}

/// Why a `.toml` file could not be read as an environment, with the line the
/// problem is on (1-based; 0 when the file could not be read at all).
public struct LocalEnvironmentParseError: Error, Hashable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var localizedDescription: String {
        line > 0 ? "第 \(line) 行：\(message)" : message
    }
}

/// One discovered environment file.
///
/// `inherited` files live in a folder between the working directory and the
/// repository root; the UI labels them "来自 {sourceFolderName} · {fileName}".
/// A file that does not parse still appears, with `parseError` set, because
/// saving is allowed to replace it.
public struct LocalEnvironmentFile: Identifiable, Hashable, Sendable {
    /// The absolute path, which is also the identity.
    public var id: String { path }
    public var path: String
    public var fileName: String
    /// The folder an inherited file's `.codex` directory sits in; `nil` for
    /// the working directory's own file.
    public var sourceFolderName: String?
    public var inherited: Bool
    public var environment: LocalEnvironment?
    public var parseError: LocalEnvironmentParseError?

    public init(
        path: String,
        fileName: String,
        sourceFolderName: String?,
        inherited: Bool,
        environment: LocalEnvironment?,
        parseError: LocalEnvironmentParseError?
    ) {
        self.path = path
        self.fileName = fileName
        self.sourceFolderName = sourceFolderName
        self.inherited = inherited
        self.environment = environment
        self.parseError = parseError
    }

    /// The name shown in lists: the parsed name, else the file name.
    public var displayName: String {
        guard let environment, !environment.name.isEmpty else { return fileName }
        return environment.name
    }
}

/// Which script a worktree run executes.
public enum LocalEnvironmentPhase: String, Sendable, Hashable {
    case setup
    case cleanup
}

/// What running one script produced.
///
/// `skipped` means nothing ran — no file, no script for this platform — which
/// is success, not failure. `exitCode` is the shell's status otherwise (127
/// when the shell could not start).
public struct LocalEnvironmentRunResult: Sendable, Hashable {
    public let exitCode: Int32
    public let output: String
    public let skipped: Bool

    public init(exitCode: Int32, output: String, skipped: Bool) {
        self.exitCode = exitCode
        self.output = output
        self.skipped = skipped
    }

    /// Nothing ran and that is fine.
    public static func skipped(_ output: String = "") -> LocalEnvironmentRunResult {
        LocalEnvironmentRunResult(exitCode: 0, output: output, skipped: true)
    }
}

/// A file the editor is about to overwrite has changed since it was read.
public struct LocalEnvironmentConflict: Error, Hashable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Official `settings.localEnvironments.save.conflict`.
    public static let message = "这个环境在磁盘上被改过了。先放弃你的未保存修改，再重新保存。"

    public var localizedDescription: String { Self.message }
}

/// Runs one script and reports what happened. Tests substitute their own.
public protocol LocalEnvironmentRunning: Sendable {
    func run(
        script: String,
        cwd: String,
        environment: [String: String],
        timeout: Double,
        outputCap: Int
    ) async -> (exitCode: Int32, output: String)
}

/// The real runner: `/bin/zsh -lc` in `cwd` with the shared child environment
/// (`ChildProcessEnvironment`) plus the caller's variables, output capped to
/// head and tail, the process stopped on timeout or cancellation.
public struct LocalEnvironmentShellRunner: LocalEnvironmentRunning {
    public init() {}

    public func run(
        script: String,
        cwd: String,
        environment: [String: String],
        timeout: Double,
        outputCap: Int
    ) async -> (exitCode: Int32, output: String) {
        #if os(macOS)
        // The whole run blocks (pipe reads, waitpid), so it happens off the
        // cooperative pool on a detached task.
        await Task.detached(priority: .userInitiated) {
            Self.runBlocking(
                script: script, cwd: cwd, environment: environment,
                timeout: timeout, outputCap: outputCap
            )
        }.value
        #else
        _ = script; _ = cwd; _ = environment; _ = timeout; _ = outputCap
        return (0, "本地环境只能在 Mac 上运行")
        #endif
    }

    #if os(macOS)
    /// Blocking execution; always called on a detached task's thread.
    private static func runBlocking(
        script: String,
        cwd: String,
        environment: [String: String],
        timeout: Double,
        outputCap: Int
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", script]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var child = ChildProcessEnvironment.build()
        for (key, value) in environment { child[key] = value }
        process.environment = child
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = HeadTail(cap: outputCap)
        let drained = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        // Blocking read on a dedicated thread: a readability handler never
        // fires without a run loop (measured in this app before).
        Thread.detachNewThread {
            let data = handle.readDataToEndOfFile()
            collector.append(data)
            drained.signal()
        }
        do {
            try process.run()
        } catch {
            drained.wait()
            return (127, "无法启动脚本：\(error.localizedDescription)")
        }
        let stopped = Interruptible()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + max(timeout, 0.1))
        timer.setEventHandler {
            stopped.stop()
            process.interrupt()
            // A script that ignores SIGINT still ends: SIGKILL two seconds on.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
        timer.resume()
        // No cooperative-cancellation wiring: the caller awaits the result,
        // and the only way a script stops early is its own timeout above.
        _ = drained.wait(timeout: .now() + max(timeout + 5, 10))
        timer.cancel()
        if process.isRunning { process.waitUntilExit() }
        let output = collector.text
        let status: Int32
        if process.terminationReason == .uncaughtSignal {
            status = 128 + process.terminationStatus
        } else {
            status = process.terminationStatus
        }
        if stopped.didStop {
            return (status, output + "\n（脚本超时，已停止）")
        }
        return (status, output)
    }

    /// Whether the timeout (or a cancellation) asked the process to stop.
    private final class Interruptible: @unchecked Sendable {
        private let lock = NSLock()
        private var stoppedState = false
        var didStop: Bool {
            lock.withLock { stoppedState }
        }
        func stop() {
            lock.withLock { stoppedState = true }
        }
    }

    /// Keeps the first and last bytes of a stream within `cap`, with a note
    /// where the middle was dropped.
    private final class HeadTail: @unchecked Sendable {
        private let lock = NSLock()
        private let halfLimit: Int
        private var head = Data()
        private var tail = Data()
        private var dropped = 0

        init(cap: Int) {
            halfLimit = max(cap / 2, 1)
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            // Head fills first; only the spill after it is full becomes the
            // rotating tail, so a small output is never shown twice.
            if head.count < halfLimit {
                let take = min(data.count, halfLimit - head.count)
                head.append(data.prefix(take))
                let rest = data.dropFirst(take)
                if !rest.isEmpty {
                    tail.append(rest)
                    if tail.count > halfLimit {
                        dropped += tail.count - halfLimit
                        tail.removeFirst(tail.count - halfLimit)
                    }
                }
                return
            }
            tail.append(data)
            if tail.count > halfLimit {
                dropped += tail.count - halfLimit
                tail.removeFirst(tail.count - halfLimit)
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            var combined = head
            if dropped > 0 {
                combined += Data("\n…（输出过长，省略中间 \(dropped) 字节）…\n".utf8)
            }
            combined += tail
            return String(decoding: combined, as: UTF8.self)
        }
    }
    #endif
}


/// Discovery, parsing, writing and running of Codex local environments.
///
/// Everything here is a function of its arguments: no process-wide state, so
/// tests drive it with temporary directories. The app layer supplies the
/// runner and caches discovery results.
public enum LocalEnvironmentDiscovery {
    /// The file the "simple setup" flow creates.
    public static let defaultFileName = "environment.toml"
    /// Explicit "no environment" selection, mirroring the official sentinel.
    public static let noneSelection = "__none__"
    /// How long a setup or cleanup script may run.
    public static let scriptTimeout: Double = 10 * 60
    /// Combined output kept from a script (head and tail).
    public static let scriptOutputCap = 64 * 1024
    /// A bigger file is not an environment anyone wrote on purpose.
    static let readLimit = 2 * 1024 * 1024

    // MARK: - Repository root

    /// The git repository root containing `directory`, or nil when it is not
    /// inside one. Walks parents looking for a `.git` directory or file (the
    /// file form is what linked worktrees carry).
    public static func repositoryRoot(containing directory: String) -> String? {
        var current = standardize(directory)
        while true {
            if FileManager.default.fileExists(atPath: joining(current, ".git")) { return current }
            let parent = parent(of: current)
            if parent == current { return nil }
            current = parent
        }
    }

    // MARK: - Discovery

    /// Every `.codex/environments/*.toml` from `directory` up to and including
    /// its repository root, nearest folder first; files of one folder come in
    /// file-name order. The working directory's own files are not inherited;
    /// every folder above it is, and is labelled with that folder's name.
    /// Nothing is discovered outside a repository.
    public static func files(inWorkingDirectory directory: String) -> [LocalEnvironmentFile] {
        let start = standardize(directory)
        guard let root = repositoryRoot(containing: start) else { return [] }
        var found: [LocalEnvironmentFile] = []
        var current = start
        while true {
            found.append(contentsOf: environmentFiles(in: current, inherited: current != start))
            if current == root { break }
            let parent = parent(of: current)
            if parent == current { break }
            current = parent
        }
        return found
    }

    /// The `.toml` files directly inside `<folder>/.codex/environments`.
    private static func environmentFiles(in folder: String, inherited: Bool) -> [LocalEnvironmentFile] {
        let environments = joining(joining(folder, ".codex"), "environments")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: environments, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: environments)) ?? []
        return names
            .filter { $0.hasSuffix(".toml") && !$0.hasPrefix(".") }
            .sorted()
            .map { name in
                readFile(
                    at: joining(environments, name),
                    fileName: name,
                    sourceFolderName: inherited ? lastComponent(of: folder) : nil,
                    inherited: inherited
                )
            }
    }

    /// Reads one file into a `LocalEnvironmentFile`, keeping a parse failure
    /// instead of dropping the file.
    public static func readFile(
        at path: String,
        fileName: String? = nil,
        sourceFolderName: String? = nil,
        inherited: Bool = false
    ) -> LocalEnvironmentFile {
        let name = fileName ?? lastComponent(of: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= readLimit, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return LocalEnvironmentFile(
                path: path, fileName: name, sourceFolderName: sourceFolderName,
                inherited: inherited, environment: nil,
                parseError: LocalEnvironmentParseError(line: 0, message: "无法读取环境文件")
            )
        }
        do {
            let environment = try LocalEnvironmentTOML.parse(text)
            return LocalEnvironmentFile(
                path: path, fileName: name, sourceFolderName: sourceFolderName,
                inherited: inherited, environment: environment, parseError: nil
            )
        } catch let error as LocalEnvironmentParseError {
            return LocalEnvironmentFile(
                path: path, fileName: name, sourceFolderName: sourceFolderName,
                inherited: inherited, environment: nil, parseError: error
            )
        } catch {
            return LocalEnvironmentFile(
                path: path, fileName: name, sourceFolderName: sourceFolderName,
                inherited: inherited, environment: nil,
                parseError: LocalEnvironmentParseError(line: 0, message: "无法读取环境文件")
            )
        }
    }

    // MARK: - Selection

    /// Which file is in force for a project.
    ///
    /// `selections` maps a standardized project root to the chosen absolute
    /// path, or to `noneSelection` for an explicit "none". The rule: the
    /// user's choice while that file still exists, otherwise the only
    /// discovered file, otherwise nil.
    public static func selectedPath(
        projectRoot: String,
        files: [LocalEnvironmentFile],
        selections: [String: String]
    ) -> String? {
        let key = standardize(projectRoot)
        if let chosen = selections[key] {
            if chosen == noneSelection { return nil }
            if files.contains(where: { standardize($0.path) == standardize(chosen) }) { return chosen }
        }
        return files.count == 1 ? files[0].path : nil
    }

    // MARK: - Saving

    /// The revision string a save compares against: size and content hash, so
    /// a change is caught even when the mtime is too coarse.
    public static func revision(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty || fileSize(ofFileAt: path) == 0 else {
            return nil
        }
        return revision(of: data)
    }

    public static func revision(of data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(data.count):\(digest)"
    }

    private static func fileSize(ofFileAt path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// Writes `environment` to `<projectRoot>/.codex/environments/<fileName>`,
    /// creating the folders.
    ///
    /// Refuses when the destination exists with a revision other than
    /// `expectedRevision` (nil only matches a file that does not exist yet),
    /// so a stale editor cannot silently clobber a newer file. Returns nil on
    /// success, otherwise a message safe to show.
    public static func save(
        _ environment: LocalEnvironment,
        toProject projectRoot: String,
        fileName: String,
        expectedRevision: String?
    ) -> String? {
        let root = standardize(projectRoot)
        let name = sanitizedFileName(fileName)
        guard !name.isEmpty else { return "环境文件名不合法" }
        let directory = joining(joining(root, ".codex"), "environments")
        let destination = joining(directory, name)
        if FileManager.default.fileExists(atPath: destination) {
            guard revision(ofFileAt: destination) == expectedRevision else {
                return LocalEnvironmentConflict.message
            }
        } else if expectedRevision != nil {
            return LocalEnvironmentConflict.message
        }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let text = LocalEnvironmentTOML.emit(environment)
            try Data(text.utf8).write(to: URL(fileURLWithPath: destination), options: .atomic)
            return nil
        } catch {
            return "无法保存环境：\(error.localizedDescription)"
        }
    }

    /// Deletes the environment file at `path`. Only a file inside some
    /// `.codex/environments` directory can go, so a bad path cannot remove
    /// anything else. Deleting an absent file succeeds.
    public static func delete(at path: String) -> String? {
        let standardized = standardize(path)
        let environments = parent(of: standardized)
        let codex = parent(of: environments)
        guard lastComponent(of: environments) == "environments",
              lastComponent(of: codex) == ".codex" else {
            return "只能删除 .codex/environments 里的环境文件"
        }
        guard FileManager.default.fileExists(atPath: standardized) else { return nil }
        do {
            try FileManager.default.removeItem(atPath: standardized)
            return nil
        } catch {
            return "无法删除环境：\(error.localizedDescription)"
        }
    }

    /// The file name a save actually uses: the base name, with `.toml` added
    /// when missing. Empty for a name that names no file.
    public static func sanitizedFileName(_ fileName: String) -> String {
        let base = lastComponent(of: fileName)
        guard !base.isEmpty, base != ".", base != ".." else { return "" }
        return base.lowercased().hasSuffix(".toml") ? base : base + ".toml"
    }

    // MARK: - Running

    /// Runs the setup or cleanup script of the environment at `configPath`.
    ///
    /// The script runs at `worktreeRoot` with `CODEX_SOURCE_TREE_PATH` and
    /// `CODEX_WORKTREE_PATH` in the environment. When `configPath` lives
    /// inside `sourceRoot` and the worktree carries its own copy at the same
    /// relative path, that copy is read — the worktree's version wins. A
    /// missing file or a script that resolves to nothing on this platform is
    /// `skipped`, not an error; an unparsable file is a failure.
    public static func runLocalEnvironmentScript(
        _ phase: LocalEnvironmentPhase,
        configPath: String,
        sourceRoot: String,
        worktreeRoot: String,
        platform: LocalEnvironmentPlatform = .current,
        timeout: Double = scriptTimeout,
        outputCap: Int = scriptOutputCap,
        runner: LocalEnvironmentRunning = LocalEnvironmentShellRunner()
    ) async -> LocalEnvironmentRunResult {
        let trimmed = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .skipped("没有选择环境，跳过")
        }
        let resolved = resolvedConfig(configPath: trimmed, sourceRoot: sourceRoot, worktreeRoot: worktreeRoot)
        let file = readFile(at: resolved)
        guard let environment = file.environment else {
            if file.parseError?.line == 0 {
                return .skipped("找不到环境文件 \(resolved)，跳过")
            }
            let detail = file.parseError?.localizedDescription ?? "无法解析"
            return LocalEnvironmentRunResult(exitCode: 1, output: "环境文件无效：\(detail)", skipped: false)
        }
        let section = phase == .cleanup ? environment.cleanup : environment.setup
        guard let script = section?.resolved(for: platform) else {
            return .skipped(phase == .cleanup ? "没有清理脚本，跳过" : "没有安装脚本，跳过")
        }
        let result = await runner.run(
            script: script,
            cwd: standardize(worktreeRoot),
            environment: [
                "CODEX_SOURCE_TREE_PATH": standardize(sourceRoot),
                "CODEX_WORKTREE_PATH": standardize(worktreeRoot),
            ],
            timeout: timeout,
            outputCap: outputCap
        )
        return LocalEnvironmentRunResult(exitCode: result.exitCode, output: result.output, skipped: false)
    }

    /// The file a run reads: the worktree copy at the same relative path when
    /// it exists, otherwise `configPath` itself. A config outside the source
    /// tree is used as-is.
    public static func resolvedConfig(configPath: String, sourceRoot: String, worktreeRoot: String) -> String {
        let config = standardize(configPath)
        let source = standardize(sourceRoot)
        guard isInside(config, source) else { return config }
        let candidate = standardize(worktreeRoot) + config.dropFirst(source.count)
        guard candidate != config, FileManager.default.fileExists(atPath: candidate) else { return config }
        return candidate
    }

    // MARK: - Paths

    /// `path` with redundant components removed and no trailing slash.
    public static func standardize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.count > 1 else { return standardized }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// Whether `path` is `root` or one of its descendants.
    static func isInside(_ path: String, _ root: String) -> Bool {
        let base = standardize(root)
        let candidate = standardize(path)
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    private static func joining(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    /// The parent directory, on the string so `/` cannot climb past itself.
    private static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private static func lastComponent(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Reads and writes the subset of TOML the official app writes for
/// environments: comments, blank lines, basic and literal strings (including
/// their multi-line forms), integers, the `[setup]` / `[cleanup]` tables with
/// their platform tables, and `[[actions]]` arrays. Unknown keys and unknown
/// tables are ignored, as the official loader does.
public enum LocalEnvironmentTOML {
    /// Parses `text` into an environment. Throws `LocalEnvironmentParseError`.
    public static func parse(_ text: String) throws -> LocalEnvironment {
        let lines = splitLines(text)
        var version: Int?
        var name: String?
        var setup = LocalEnvironmentScript()
        var cleanup = LocalEnvironmentScript()
        var sawCleanup = false
        var actions: [LocalEnvironmentAction] = []
        var section: Section = .top
        var action = ActionDraft()

        func finishAction() throws {
            guard section == .action else { return }
            if let built = try action.build() { actions.append(built) }
            action = ActionDraft()
        }

        var index = 0
        while index < lines.count {
            let lineNumber = index + 1
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") {
                try finishAction()
                section = try openSection(trimmed, line: lineNumber)
                if case .table(.cleanup, _) = section { sawCleanup = true }
                continue
            }

            let (key, value) = try keyValue(trimmed, line: lineNumber, lines: lines, index: &index)
            switch section {
            case .top:
                switch key {
                case "version":
                    guard let number = Int(value), number >= 1 else {
                        throw LocalEnvironmentParseError(line: lineNumber, message: "version 必须是不小于 1 的整数")
                    }
                    version = number
                case "name":
                    name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                default:
                    break
                }
            case .table(let group, let platform):
                guard key == "script" else { break }
                // Verbatim: multi-line scripts keep every newline and space.
                let stored = value
                switch group {
                case .setup: assign(stored, platform: platform, to: &setup)
                case .cleanup:
                    sawCleanup = true
                    assign(stored, platform: platform, to: &cleanup)
                }
            case .action:
                action.take(key: key, value: value, line: lineNumber)
            case .unknown:
                break
            }
        }
        try finishAction()

        guard let name else {
            throw LocalEnvironmentParseError(line: 1, message: "环境缺少 name")
        }
        return LocalEnvironment(
            version: version ?? 1,
            name: name,
            setup: setup,
            cleanup: sawCleanup ? cleanup : nil,
            actions: actions
        )
    }

    /// The official writer's layout: a generated-file banner, `version` and
    /// `name`, then `[setup]` (always, even when empty), then `[cleanup]` only
    /// when it has content, then one `[[actions]]` block per action that has
    /// both a name and a command, ending with exactly one newline.
    public static func emit(_ environment: LocalEnvironment) -> String {
        var lines: [String] = []
        lines.append("# THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY")
        lines.append("version = \(max(environment.version, 1))")
        lines.append("name = \(quote(environment.name.trimmingCharacters(in: .whitespacesAndNewlines)))")
        emitScript(environment.setup, group: "setup", always: true, into: &lines)
        if let cleanup = environment.cleanup {
            emitScript(cleanup, group: "cleanup", always: false, into: &lines)
        }
        let actions = environment.actions.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !actions.isEmpty { lines.append("") }
        for action in actions {
            lines.append("[[actions]]")
            lines.append("name = \(quote(action.name))")
            if let icon = action.icon, !icon.isEmpty { lines.append("icon = \(quote(icon))") }
            lines.append("command = \(quote(action.command))")
            if let platform = action.platform, !platform.isEmpty {
                lines.append("platform = \(quote(platform))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: Writing

    private static func emitScript(
        _ script: LocalEnvironmentScript,
        group: String,
        always: Bool,
        into lines: inout [String]
    ) {
        let overrides = LocalEnvironmentPlatform.allCases.compactMap { platform -> (LocalEnvironmentPlatform, String)? in
            guard let value = script.overrides[platform], !value.isEmpty else { return nil }
            return (platform, value)
        }
        guard always || !script.script.isEmpty || !overrides.isEmpty else { return }
        lines.append("")
        lines.append("[\(group)]")
        lines.append("script = \(quote(script.script))")
        guard !overrides.isEmpty else { return }
        for entry in overrides {
            lines.append("")
            lines.append("[\(group).\(entry.0.rawValue)]")
            lines.append("script = \(quote(entry.1))")
        }
    }

    /// One TOML string, in the official writer's style: always a single-line
    /// basic string (`JSON.stringify` encoding — newlines are `\n` escapes),
    /// never a multi-line literal. The reader still accepts multi-line
    /// strings for hand-written files.
    static func quote(_ value: String) -> String {
        basicString(value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    /// A TOML basic string, which is exactly JSON's string encoding.
    private static func basicString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F, 0x7F:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    // MARK: Reading

    private enum Group { case setup, cleanup }

    private enum Section: Equatable {
        case top
        case table(Group, LocalEnvironmentPlatform?)
        case action
        case unknown
    }

    /// One `[[actions]]` entry while its keys are still arriving.
    private struct ActionDraft {
        var name: String?
        var icon: String?
        var command: String?
        var platform: String?
        var invalidPlatformLine = 0
        var invalidPlatformValue: String?

        mutating func take(key: String, value: String, line: Int) {
            let stored = value
            switch key {
            case "name": name = stored
            case "command": command = stored
            case "icon": icon = stored.isEmpty ? nil : stored
            case "platform":
                // An unknown platform fails the file; an empty one means "all".
                if !stored.isEmpty, LocalEnvironmentPlatform(rawValue: stored) == nil {
                    invalidPlatformLine = line
                    invalidPlatformValue = stored
                } else {
                    platform = stored.isEmpty ? nil : stored
                }
            default:
                break
            }
        }

        /// A name/command pair where either side is missing drops the action,
        /// exactly as the official loader does; an invalid platform is a file
        /// error reported at that key's line.
        func build() throws -> LocalEnvironmentAction? {
            if let value = invalidPlatformValue {
                throw LocalEnvironmentParseError(
                    line: max(invalidPlatformLine, 1), message: "未知的平台「\(value)」"
                )
            }
            let trimmedName = name ?? ""
            let trimmedCommand = command ?? ""
            if trimmedName.isEmpty || trimmedCommand.isEmpty { return nil }
            var icon = self.icon
            if let raw = icon, !["tool", "run", "test", "debug"].contains(raw) { icon = nil }
            return LocalEnvironmentAction(name: trimmedName, icon: icon, command: trimmedCommand, platform: platform)
        }
    }

    private static func assign(_ value: String, platform: LocalEnvironmentPlatform?, to script: inout LocalEnvironmentScript) {
        if let platform {
            if value.isEmpty { script.overrides.removeValue(forKey: platform) } else { script.overrides[platform] = value }
        } else {
            script.script = value
        }
    }

    private static func openSection(_ text: String, line: Int) throws -> Section {
        if text.hasPrefix("[[") {
            guard text.hasSuffix("]]") else {
                throw LocalEnvironmentParseError(line: line, message: "无效的表头")
            }
            let name = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard name == "actions" else { return .unknown }
            return .action
        }
        guard text.hasPrefix("["), text.hasSuffix("]") else {
            throw LocalEnvironmentParseError(line: line, message: "无效的表头")
        }
        let name = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count <= 2 else { return .unknown }
        guard let group = group(parts[0]) else { return .unknown }
        if parts.count == 2 {
            guard let platform = LocalEnvironmentPlatform(rawValue: parts[1]) else {
                throw LocalEnvironmentParseError(line: line, message: "未知的平台「\(parts[1])」")
            }
            return .table(group, platform)
        }
        return .table(group, nil)
    }

    private static func group(_ name: String) -> Group? {
        switch name {
        case "setup": .setup
        case "cleanup": .cleanup
        default: nil
        }
    }

    /// One `key = value`, where the value may open a multi-line string that
    /// consumes the following lines.
    private static func keyValue(
        _ text: String,
        line: Int,
        lines: [String],
        index: inout Int
    ) throws -> (String, String) {
        guard let separator = text.firstIndex(of: "=") else {
            throw LocalEnvironmentParseError(line: line, message: "缺少等号")
        }
        let key = text[..<separator].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" || $0.isNumber }) else {
            throw LocalEnvironmentParseError(line: line, message: "无效的键名")
        }
        let rawValue = String(text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces))
        let value = try readValue(rawValue, line: line, lines: lines, index: &index)
        return (key, value)
    }

    private static func readValue(
        _ raw: String,
        line: Int,
        lines: [String],
        index: inout Int
    ) throws -> String {
        if raw == "'''" || raw == "\"\"\"" {
            return try multiline(delimiter: raw, line: line, lines: lines, index: &index, first: nil)
        }
        if raw.hasPrefix("\"\"\"") {
            return try multiline(delimiter: "\"\"\"", line: line, lines: lines, index: &index, first: String(raw.dropFirst(3)))
        }
        if raw.hasPrefix("'''") {
            return try multiline(delimiter: "'''", line: line, lines: lines, index: &index, first: String(raw.dropFirst(3)))
        }
        if raw.hasPrefix("\"") { return try basic(raw, line: line) }
        if raw.hasPrefix("'") { return try literal(raw, line: line) }
        if Int(raw) != nil { return raw }
        throw LocalEnvironmentParseError(line: line, message: "无法识别的值")
    }

    /// A single-line basic string with TOML escapes. Whatever follows the
    /// closing quote must be a comment or nothing.
    private static func basic(_ raw: String, line: Int) throws -> String {
        let scalars = Array(raw.dropFirst().unicodeScalars)
        var out = ""
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            position += 1
            if scalar == "\"" {
                let rest = scalars[position...]
                let trailing = String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
                guard trailing.isEmpty || trailing.hasPrefix("#") else {
                    throw LocalEnvironmentParseError(line: line, message: "字符串后面有多余内容")
                }
                return out
            }
            if scalar == "\\" {
                guard position < scalars.count else {
                    throw LocalEnvironmentParseError(line: line, message: "字符串以反斜杠结尾")
                }
                let escaped = scalars[position]
                position += 1
                switch escaped {
                case "b": out += "\u{08}"
                case "t": out += "\t"
                case "n": out += "\n"
                case "f": out += "\u{0C}"
                case "r": out += "\r"
                case "\"": out += "\""
                case "\\": out += "\\"
                case "u", "U":
                    let count = escaped == "u" ? 4 : 8
                    guard scalars.count >= position + count else {
                        throw LocalEnvironmentParseError(line: line, message: "无效的 \\u 转义")
                    }
                    let digits = String(String.UnicodeScalarView(scalars[position..<position + count]))
                    position += count
                    guard let value = UInt32(digits, radix: 16), let decoded = UnicodeScalar(value) else {
                        throw LocalEnvironmentParseError(line: line, message: "无效的 \\u 转义")
                    }
                    out.unicodeScalars.append(decoded)
                default:
                    throw LocalEnvironmentParseError(line: line, message: "无效的转义 \\\(escaped)")
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        throw LocalEnvironmentParseError(line: line, message: "字符串没有结束引号")
    }

    /// A single-line literal string: no escapes at all.
    private static func literal(_ raw: String, line: Int) throws -> String {
        let body = raw.dropFirst()
        guard let end = body.firstIndex(of: "'") else {
            throw LocalEnvironmentParseError(line: line, message: "字符串没有结束引号")
        }
        let trailing = String(body[body.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else {
            throw LocalEnvironmentParseError(line: line, message: "字符串后面有多余内容")
        }
        return String(body[..<end])
    }

    /// A multi-line string opened by `delimiter`, possibly with content on
    /// the opening line (`first`). The official writer always puts the content
    /// on the following lines; both are accepted.
    private static func multiline(
        delimiter: String,
        line: Int,
        lines: [String],
        index: inout Int,
        first: String?
    ) throws -> String {
        var collected: [String] = []
        if let first {
            // The closing delimiter sits right on the opening line
            // (`''''''` or `""""""`): empty content.
            if first.isEmpty || first == delimiter {
                return ""
            }
            if let (content, remainder) = close(delimiter, in: first) {
                try checkTrailing(remainder, line: line)
                return try decode(delimiter, content, line: line)
            }
            collected.append(first)
        }
        let startLine = line
        while index < lines.count {
            let current = lines[index]
            index += 1
            if let (content, remainder) = close(delimiter, in: current) {
                try checkTrailing(remainder, line: index)
                collected.append(content)
                var text = collected.joined(separator: "\n")
                // A newline straight after the opening delimiter is trimmed.
                if first == nil, text.hasPrefix("\n") { text.removeFirst() }
                return try decode(delimiter, text, line: startLine)
            }
            collected.append(current)
        }
        throw LocalEnvironmentParseError(line: startLine, message: "多行字符串没有结束")
    }

    /// Splits `line` at the position where `delimiter` closes. The closing
    /// delimiter is the LAST three quotes of a quote run, so a content quote
    /// glued to it (`a''''`) stays in the content. Returns the content before
    /// the delimiter and whatever trailed it.
    private static func close(_ delimiter: String, in line: String) -> (String, String)? {
        var searchStart = line.startIndex
        while let range = line.range(of: delimiter, range: searchStart..<line.endIndex) {
            if delimiter == "\"\"\"" {
                var slashes = 0
                var cursor = range.lowerBound
                while cursor > line.startIndex {
                    cursor = line.index(before: cursor)
                    if line[cursor] == "\\" { slashes += 1 } else { break }
                }
                if slashes % 2 == 1 {
                    searchStart = range.upperBound
                    continue
                }
            }
            var runEnd = range.upperBound
            while runEnd < line.endIndex, line[runEnd] == delimiter.first! {
                runEnd = line.index(after: runEnd)
            }
            let closeStart = line.index(runEnd, offsetBy: -3)
            let content = String(line[line.startIndex..<closeStart])
            let remainder = String(line[runEnd...])
            return (content, remainder)
        }
        return nil
    }

    private static func checkTrailing(_ remainder: String, line: Int) throws {
        let trailing = remainder.trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else {
            throw LocalEnvironmentParseError(line: line, message: "多行字符串结束后有多余内容")
        }
    }

    /// Unescapes the collected body of a multi-line string. A literal body is
    /// already final; a basic body has escapes but no closing quote of its own.
    private static func decode(_ delimiter: String, _ text: String, line: Int) throws -> String {
        guard delimiter == "\"\"\"" else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = ""
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            position += 1
            if scalar != "\\" {
                out.unicodeScalars.append(scalar)
                continue
            }
            guard position < scalars.count else {
                throw LocalEnvironmentParseError(line: line, message: "字符串以反斜杠结尾")
            }
            let escaped = scalars[position]
            position += 1
            switch escaped {
            case "b": out += "\u{08}"
            case "t": out += "\t"
            case "n": out += "\n"
            case "f": out += "\u{0C}"
            case "r": out += "\r"
            case "\"": out += "\""
            case "\\": out += "\\"
            case "u", "U":
                let count = escaped == "u" ? 4 : 8
                guard scalars.count >= position + count else {
                    throw LocalEnvironmentParseError(line: line, message: "无效的 \\u 转义")
                }
                let digits = String(String.UnicodeScalarView(scalars[position..<position + count]))
                position += count
                guard let value = UInt32(digits, radix: 16), let decoded = UnicodeScalar(value) else {
                    throw LocalEnvironmentParseError(line: line, message: "无效的 \\u 转义")
                }
                out.unicodeScalars.append(decoded)
            default:
                throw LocalEnvironmentParseError(line: line, message: "无效的转义 \\\(escaped)")
            }
        }
        return out
    }

    /// Splits on `\n`, tolerating `\r\n` and a final newline.
    private static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
    }
}
