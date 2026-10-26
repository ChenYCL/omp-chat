import Foundation
import OMPCore

/// The built-in file and shell tools, registered as provider "builtin".
/// macOS runs them for real against the thread's working directory. iOS has
/// no `Process` and no Mac file system to reach, so it offers none.
public struct BuiltinToolProvider: AgentToolProvider {
    public static let providerID = "builtin"
    static let source = "内置"
    static let defaultShellTimeout: Double = 120
    static let maxShellTimeout: Double = 600
    static let shellOutputCap = 64 * 1024
    /// Most text one `read_file` returns, and the most lines by default.
    static let readOutputCap = 256 * 1024
    static let defaultReadLines = 2000
    /// Larger files are refused rather than loaded whole.
    static let readFileLimit = 20 * 1024 * 1024
    static let listEntryCap = 1000

    /// Home used to expand `~`; tests point it at a temporary directory.
    private let home: String

    public init(home: String? = nil) {
        self.home = home ?? HostExecutor.realHomeDirectory()
    }

    public func tools() async -> [AgentToolSpec] {
        #if os(macOS)
        Self.specs
        #else
        []
        #endif
    }

    static let specs: [AgentToolSpec] = [
        AgentToolSpec(
            name: "read_file",
            description: "读取文本文件。相对路径以工作目录为准。offset 是起始行号（从 1 开始），limit 是行数，默认最多 2000 行。",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"文件路径"},"offset":{"type":"integer","description":"起始行号，从 1 开始"},"limit":{"type":"integer","description":"读取的行数"}},"required":["path"]}"#,
            risk: .read, source: source
        ),
        AgentToolSpec(
            name: "list_dir",
            description: "列出目录内容，目录名以 / 结尾。相对路径以工作目录为准。",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"目录路径，默认是工作目录"}},"required":["path"]}"#,
            risk: .read, source: source
        ),
        AgentToolSpec(
            name: "write_file",
            description: "把 content 整个写入文件，文件不存在就创建（含上级目录），存在就覆盖。",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"文件路径"},"content":{"type":"string","description":"完整的新内容"}},"required":["path","content"]}"#,
            risk: .write, source: source
        ),
        AgentToolSpec(
            name: "edit_file",
            description: "把文件里的 old_string 精确替换成 new_string。old_string 必须原样出现且只出现一次；要替换所有出现处时设 replace_all 为 true。找不到或不唯一时文件不会改动。",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"文件路径"},"old_string":{"type":"string","description":"要替换的原文，需与文件内容逐字一致"},"new_string":{"type":"string","description":"替换后的文本"},"replace_all":{"type":"boolean","description":"替换所有出现处"}},"required":["path","old_string","new_string"]}"#,
            risk: .write, source: source
        ),
        AgentToolSpec(
            name: "shell",
            description: "在工作目录里用 zsh 运行一条命令，返回合并的 stdout/stderr 和退出码。默认超时 120 秒，最长 600 秒；超时会终止整个进程树。",
            parametersJSON: #"{"type":"object","properties":{"command":{"type":"string","description":"要运行的命令"},"timeout_seconds":{"type":"number","description":"超时秒数，默认 120，最大 600"}},"required":["command"]}"#,
            risk: .execute, source: source
        ),
    ]

    public func risk(forCall name: String, argumentsJSON: String, context: AgentToolContext) async -> ToolRisk {
        let access: AgentPathPolicy.Access
        switch name {
        case "read_file", "list_dir": access = .read
        case "write_file", "edit_file": access = .write
        default: return .execute
        }
        // A call that cannot name a path fails before touching anything.
        guard let arguments = Self.object(argumentsJSON),
              let path = targetPath(name, arguments, context) else { return .read }
        return AgentPathPolicy.risk(
            of: path, access: access,
            workingDirectory: context.workingDirectory, readableRoots: context.readableRoots
        )
    }

    public func summary(forCall name: String, argumentsJSON: String) -> String {
        let arguments = Self.object(argumentsJSON) ?? [:]
        let path = (arguments["path"] as? String) ?? ""
        switch name {
        case "shell":
            let command = (arguments["command"] as? String) ?? ""
            let line = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
            return "运行命令：\(line.count > 120 ? String(line.prefix(120)) + "…" : line)"
        case "read_file": return "读取文件：\(path)"
        case "list_dir": return "列出目录：\(path.isEmpty ? "." : path)"
        case "write_file":
            let bytes = ((arguments["content"] as? String) ?? "").utf8.count
            return "写入文件：\(path)（\(bytes) 字节）"
        case "edit_file":
            return (arguments["replace_all"] as? Bool) == true ? "编辑文件（全部替换）：\(path)" : "编辑文件：\(path)"
        default:
            return name
        }
    }

    public func call(_ name: String, argumentsJSON: String, context: AgentToolContext) async throws -> AgentToolOutput {
        #if os(macOS)
        guard let arguments = Self.object(argumentsJSON) else {
            return AgentToolOutput(text: AgentLoop.invalidArgumentsText, isError: true)
        }
        switch name {
        case "shell":
            return await shell(arguments, context)
        case "read_file", "list_dir", "write_file", "edit_file":
            guard let path = targetPath(name, arguments, context) else {
                return AgentToolOutput(text: Self.pathProblem(arguments, context), isError: true)
            }
            // Act on the physical path the risk check judged, so a symlink
            // cannot point the write somewhere the check did not look.
            let physical = AgentPathPolicy.canonical(path)
            switch name {
            case "read_file": return Self.readFile(physical, arguments)
            case "list_dir": return Self.listDirectory(physical)
            case "write_file": return Self.writeFile(physical, arguments)
            default: return Self.editFile(physical, arguments)
            }
        default:
            return AgentToolOutput(text: "没有名为「\(name)」的内置工具", isError: true)
        }
        #else
        return AgentToolOutput(text: "iPhone 上不能运行内置工具", isError: true)
        #endif
    }

    // MARK: Arguments

    static func object(_ json: String) -> [String: Any]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    /// The absolute path a file tool targets; nil when it cannot be resolved.
    private func targetPath(_ name: String, _ arguments: [String: Any], _ context: AgentToolContext) -> String? {
        let raw = (arguments["path"] as? String) ?? (name == "list_dir" ? "." : "")
        return AgentPathPolicy.resolve(raw, workingDirectory: context.workingDirectory, home: home)
    }

    private static func pathProblem(_ arguments: [String: Any], _ context: AgentToolContext) -> String {
        let raw = ((arguments["path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "缺少 path 参数" }
        if context.workingDirectory == nil { return "这个对话没有工作目录，不能使用相对路径「\(raw)」，请改用绝对路径" }
        return "路径无效：\(raw)"
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    // MARK: Files

    static func readFile(_ path: String, _ arguments: [String: Any]) -> AgentToolOutput {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return AgentToolOutput(text: "文件不存在：\(path)", isError: true)
        }
        if isDirectory.boolValue { return AgentToolOutput(text: "这是目录，请用 list_dir：\(path)", isError: true) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size <= readFileLimit else {
            return AgentToolOutput(text: "文件太大（\(size / 1024 / 1024) MB），请用 shell 配合 head、tail 或 sed 读取片段", isError: true)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return AgentToolOutput(text: "读取失败：\(error.localizedDescription)", isError: true)
        }
        if data.prefix(8192).contains(0) {
            return AgentToolOutput(text: "这是二进制文件（\(data.count) 字节），不能按文本读取", isError: true)
        }
        if data.isEmpty { return AgentToolOutput(text: "（空文件）") }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        let total = lines.count
        let start = max(int(arguments["offset"]) ?? 1, 1)
        let limit = max(int(arguments["limit"]) ?? defaultReadLines, 1)
        guard start <= total else {
            return AgentToolOutput(text: "offset \(start) 超出了文件末尾（共 \(total) 行）", isError: true)
        }
        var output = ""
        var last = start - 1
        for index in (start - 1)..<(start - 1 + min(limit, total - start + 1)) {
            let line = lines[index]
            if output.utf8.count + line.utf8.count + 1 > readOutputCap, index > start - 1 { break }
            output += line + "\n"
            last = index + 1
        }
        if start > 1 || last < total {
            output += "…（第 \(start)–\(last) 行，共 \(total) 行；用 offset 和 limit 读取其余部分）"
        } else {
            output.removeLast()
        }
        return AgentToolOutput(text: output)
    }

    static func listDirectory(_ path: String) -> AgentToolOutput {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return AgentToolOutput(text: "目录不存在：\(path)", isError: true)
        }
        guard isDirectory.boolValue else { return AgentToolOutput(text: "这不是目录：\(path)", isError: true) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        } catch {
            return AgentToolOutput(text: "无法列出目录：\(error.localizedDescription)", isError: true)
        }
        if names.isEmpty { return AgentToolOutput(text: "（空目录）") }
        var lines: [String] = []
        for name in names.prefix(listEntryCap) {
            var childIsDirectory: ObjCBool = false
            let child = (path as NSString).appendingPathComponent(name)
            _ = FileManager.default.fileExists(atPath: child, isDirectory: &childIsDirectory)
            lines.append(childIsDirectory.boolValue ? name + "/" : name)
        }
        if names.count > listEntryCap {
            lines.append("…（共 \(names.count) 项，只列出前 \(listEntryCap) 项）")
        }
        return AgentToolOutput(text: lines.joined(separator: "\n"))
    }

    static func writeFile(_ path: String, _ arguments: [String: Any]) -> AgentToolOutput {
        guard let content = arguments["content"] as? String else {
            return AgentToolOutput(text: "缺少 content 参数", isError: true)
        }
        var isDirectory: ObjCBool = false
        let existed = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if existed, isDirectory.boolValue { return AgentToolOutput(text: "这是目录，不能写入：\(path)", isError: true) }
        do {
            let parent = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try replaceContents(of: path, with: Data(content.utf8))
        } catch {
            return AgentToolOutput(text: "写入失败：\(error.localizedDescription)", isError: true)
        }
        return AgentToolOutput(text: "已\(existed ? "覆盖" : "创建") \(path)（\(content.utf8.count) 字节）")
    }

    static func editFile(_ path: String, _ arguments: [String: Any]) -> AgentToolOutput {
        guard let old = arguments["old_string"] as? String, let new = arguments["new_string"] as? String else {
            return AgentToolOutput(text: "缺少 old_string 或 new_string 参数", isError: true)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return AgentToolOutput(text: "文件不存在：\(path)。新文件请用 write_file", isError: true)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return AgentToolOutput(text: "读取失败：\(error.localizedDescription)", isError: true)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return AgentToolOutput(text: "文件不是 UTF-8 文本，不能编辑", isError: true)
        }
        let replaceAll = (arguments["replace_all"] as? Bool) ?? false
        let edit: TextReplacement.Outcome
        switch TextReplacement.apply(old: old, new: new, replaceAll: replaceAll, in: text) {
        case .success(let outcome): edit = outcome
        case .failure(let problem): return AgentToolOutput(text: problem.message + "，文件未改动", isError: true)
        }
        do {
            try replaceContents(of: path, with: Data(edit.text.utf8))
        } catch {
            return AgentToolOutput(text: "写入失败：\(error.localizedDescription)，文件未改动", isError: true)
        }
        return AgentToolOutput(text: "已编辑 \(path)（替换 \(edit.count) 处）\n" + TextReplacement.diff(old: old, new: new, count: edit.count))
    }

    /// Atomic replace that keeps the file's permission bits (an edited
    /// script stays executable).
    private static func replaceContents(of path: String, with data: Data) throws {
        let permissions = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }

    // MARK: Shell

    #if os(macOS)
    private func shell(_ arguments: [String: Any], _ context: AgentToolContext) async -> AgentToolOutput {
        let command = ((arguments["command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return AgentToolOutput(text: "缺少 command 参数", isError: true) }
        let requested = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? Self.defaultShellTimeout
        let timeout = min(max(requested, 1), Self.maxShellTimeout)
        var note = ""
        let cwd: String
        if let directory = context.workingDirectory, !directory.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                return AgentToolOutput(text: "工作目录不存在：\(directory)", isError: true)
            }
            cwd = directory
        } else {
            cwd = home
            note = "（这个对话没有工作目录，命令在家目录运行）\n"
        }
        let run = await HostExecutor.runCommand(
            command, cwd: cwd, timeout: timeout,
            outputCap: Self.shellOutputCap, loginShell: true, mergeStderr: true
        )
        if let launchError = run.launchError {
            return AgentToolOutput(text: "无法启动 zsh：\(launchError)", isError: true)
        }
        var text = note + (run.stdout.isEmpty ? "（没有输出）" : run.stdout)
        if !text.hasSuffix("\n") { text += "\n" }
        if run.timedOut {
            text += "命令超时（\(Int(timeout)) 秒），已终止整个进程树"
        } else if run.cancelled {
            text += "命令被用户停止，已终止整个进程树"
        } else {
            text += "退出码：\(run.exitCode)"
        }
        return AgentToolOutput(text: text, isError: run.timedOut || run.cancelled || run.exitCode != 0)
    }
    #endif
}

/// Exact-text replacement for `edit_file`: matches code units literally (no
/// Unicode folding) and refuses rather than guess when the target is missing
/// or ambiguous.
enum TextReplacement {
    struct Outcome: Equatable {
        var text: String
        var count: Int
    }

    enum Problem: Error, Equatable {
        case emptyOld
        case unchanged
        case notFound
        case ambiguous(Int)

        var message: String {
            switch self {
            case .emptyOld: "old_string 不能为空"
            case .unchanged: "old_string 和 new_string 相同，没有可改的"
            case .notFound: "没有找到 old_string（需与文件内容逐字一致，包括空白和换行）"
            case .ambiguous(let count): "old_string 出现了 \(count) 次。请多带一些上下文让它唯一，或设 replace_all 为 true"
            }
        }
    }

    static func apply(old: String, new: String, replaceAll: Bool, in text: String) -> Result<Outcome, Problem> {
        guard !old.isEmpty else { return .failure(.emptyOld) }
        guard old != new else { return .failure(.unchanged) }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: old, options: .literal, range: searchStart..<text.endIndex) {
            ranges.append(found)
            searchStart = found.upperBound
        }
        if ranges.isEmpty { return .failure(.notFound) }
        if ranges.count > 1 && !replaceAll { return .failure(.ambiguous(ranges.count)) }
        var result = text
        for range in ranges.reversed() {
            result.replaceSubrange(range, with: new)
        }
        return .success(Outcome(text: result, count: ranges.count))
    }

    /// `-old` / `+new` lines for the result, so the activity row's diff chip
    /// counts the change. Capped so a large `replace_all` stays readable.
    static func diff(old: String, new: String, count: Int, lineCap: Int = 200) -> String {
        var lines = old.components(separatedBy: "\n").map { "-" + $0 }
        lines += new.isEmpty ? [] : new.components(separatedBy: "\n").map { "+" + $0 }
        var output: [String] = []
        for _ in 0..<max(count, 1) where output.count <= lineCap {
            output += lines
        }
        if output.count > lineCap {
            output = Array(output.prefix(lineCap)) + ["…（差异过长，已省略）"]
        }
        return output.joined(separator: "\n")
    }
}
