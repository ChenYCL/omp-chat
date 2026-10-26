import Foundation

/// One installable server in 设置 → MCP 服务器 → 目录.
public struct MCPCatalogEntry: Identifiable, Hashable, Sendable {
    /// Something the user must answer before the server can start.
    public struct Input: Identifiable, Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            /// A file-system path, picked with an open panel.
            case path
            /// Stored in the secrets vault, never in `workspace.json`.
            case secret
            case text
        }

        public enum Target: Hashable, Sendable {
            /// Every answer is appended to `args` (filesystem's directories).
            case arguments
            /// `flag answer` is appended to `args`.
            case flag(String)
            /// An environment variable. A `.secret` answer goes to the vault.
            case environment(String)
            /// A file named `fileName` inside the chosen folder, passed as an
            /// environment variable.
            case environmentFile(String, fileName: String)
        }

        public var id: String
        public var label: String
        public var help: String
        public var kind: Kind
        public var target: Target
        public var required: Bool
        public var allowsMultiple: Bool

        public init(
            id: String, label: String, help: String, kind: Kind, target: Target,
            required: Bool, allowsMultiple: Bool = false
        ) {
            self.id = id
            self.label = label
            self.help = help
            self.kind = kind
            self.target = target
            self.required = required
            self.allowsMultiple = allowsMultiple
        }
    }

    /// The config to add, plus secret values for the vault (their variables
    /// are in `config.env` with blank values).
    public struct Installation: Equatable, Sendable {
        public var config: MCPServerConfig
        public var secrets: [String: String]
    }

    public enum InstallError: Error, Equatable, LocalizedError {
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let label): "请填写「\(label)」"
            }
        }
    }

    public var id: String
    public var name: String
    /// One or two sentences in Chinese.
    public var summary: String
    /// Pinned: `args` name an exact package version, never `@latest`.
    public var template: MCPServerConfig
    public var runtime: MCPRuntime?
    /// Version or companion requirements beyond the runtime, e.g. "Node.js 24+".
    public var requirement: String?
    public var inputs: [Input]
    public var homepage: String
    public var license: String

    public init(
        id: String, name: String, summary: String, template: MCPServerConfig,
        runtime: MCPRuntime?, requirement: String? = nil, inputs: [Input] = [],
        homepage: String, license: String
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.template = template
        self.runtime = runtime
        self.requirement = requirement
        self.inputs = inputs
        self.homepage = homepage
        self.license = license
    }

    /// True when `config` runs this entry's package (any version of the
    /// arguments the user added after it).
    public func matches(_ config: MCPServerConfig) -> Bool {
        if let url = template.url { return config.url == url }
        return config.command == template.command && config.args.starts(with: template.args)
    }

    /// Applies the answers (keyed by input id) to the template. `~` in path
    /// answers expands to `home`; the id is made unique against `existingIDs`.
    public func install(values: [String: [String]], existingIDs: Set<String>, home: String) throws -> Installation {
        var config = template
        config.origin = "catalog"
        config.id = Self.uniqueID(template.id, existing: existingIDs)
        var secrets: [String: String] = [:]
        for input in inputs {
            var answers = (values[input.id] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if input.kind == .path { answers = answers.map { MCPLaunchPlanner.expandTilde($0, home: home) } }
            guard let first = answers.first else {
                if input.required { throw InstallError.missing(input.label) }
                continue
            }
            switch input.target {
            case .arguments:
                config.args += input.allowsMultiple ? answers : [first]
            case .flag(let flag):
                config.args += [flag, first]
            case .environment(let name):
                if input.kind == .secret {
                    config.env[name] = ""
                    secrets[name] = first
                } else {
                    config.env[name] = first
                }
            case .environmentFile(let name, let fileName):
                config.env[name] = (first as NSString).appendingPathComponent(fileName)
            }
        }
        return Installation(config: config, secrets: secrets)
    }

    static func uniqueID(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}

/// Open-source servers that install with one click.
///
/// Every entry was checked on 2026-10-26 against its repository README and
/// package registry, then launched at the pinned version with this app's
/// client handshake (`initialize` at 2025-06-18 → `tools/list`); the tool
/// counts below are what that run returned. Bump a version only after the
/// same check.
public enum MCPCatalog {
    /// Desktop-control servers are deliberately not listed here: they are added
    /// only from 设置 → 电脑控制 (`ComputerUseCatalog`), after a warning about
    /// what they can see and do. A one-click install here would skip it.
    public static let entries: [MCPCatalogEntry] = [
        // https://github.com/microsoft/playwright-mcp — Apache-2.0.
        // npm @playwright/mcp 0.0.83 (2026-09-28), engines node >=18.
        // Verified 2026-10-26: protocol 2025-06-18, 25 tools.
        MCPCatalogEntry(
            id: "playwright", name: "Playwright",
            summary: "微软的浏览器自动化服务器：在独立的浏览器里打开网页、点击、输入、填表、截图，并按无障碍树读取页面。",
            template: MCPServerConfig(
                id: "playwright", name: "Playwright", command: "npx",
                args: ["-y", "@playwright/mcp@0.0.83"], risk: .execute, origin: "catalog"
            ),
            runtime: .node, requirement: "Node.js 18+",
            homepage: "https://github.com/microsoft/playwright-mcp", license: "Apache-2.0"
        ),
        // https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem
        // README: MIT; the repo is relicensing new work to Apache-2.0.
        // npm @modelcontextprotocol/server-filesystem 2.0.1 (2026-10-25),
        // engines node >=24. Allowed directories are command-line arguments.
        // Verified 2026-10-26: protocol 2025-06-18, 14 tools.
        MCPCatalogEntry(
            id: "filesystem", name: "Filesystem",
            summary: "官方参考服务器：在你指定的文件夹里读写、搜索、移动文件，访问不出这些文件夹。",
            template: MCPServerConfig(
                id: "filesystem", name: "Filesystem", command: "npx",
                args: ["-y", "@modelcontextprotocol/server-filesystem@2.0.1"], risk: .write, origin: "catalog"
            ),
            runtime: .node, requirement: "Node.js 24+",
            inputs: [
                MCPCatalogEntry.Input(
                    id: "directories", label: "允许访问的文件夹",
                    help: "服务器只能读写这些文件夹里的内容，至少选一个。",
                    kind: .path, target: .arguments, required: true, allowsMultiple: true
                ),
            ],
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem",
            license: "MIT / Apache-2.0"
        ),
        // https://github.com/modelcontextprotocol/servers/tree/main/src/fetch — MIT.
        // PyPI mcp-server-fetch 2026.10.24 (2026-10-25), requires Python >=3.10
        // (uvx provides it). Verified 2026-10-26: protocol 2025-06-18, 1 tool.
        MCPCatalogEntry(
            id: "fetch", name: "Fetch",
            summary: "官方参考服务器：抓取网页并转成 Markdown 给模型阅读。能访问本机和局域网地址，调用前会询问。",
            template: MCPServerConfig(
                id: "fetch", name: "Fetch", command: "uvx",
                args: ["mcp-server-fetch==2026.10.24"], risk: .execute, origin: "catalog"
            ),
            runtime: .uv,
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/fetch", license: "MIT"
        ),
        // https://github.com/modelcontextprotocol/servers/tree/main/src/git — MIT.
        // PyPI mcp-server-git 2026.10.19 (2026-10-19). `--repository` limits it
        // to one repository; without it every call names its `repo_path`.
        // Verified 2026-10-26: protocol 2025-06-18, 12 tools.
        MCPCatalogEntry(
            id: "git", name: "Git",
            summary: "官方参考服务器：查看状态、差异、日志，暂存、提交、建分支和切换分支。",
            template: MCPServerConfig(
                id: "git", name: "Git", command: "uvx",
                args: ["mcp-server-git==2026.10.19"], risk: .write, origin: "catalog"
            ),
            runtime: .uv,
            inputs: [
                MCPCatalogEntry.Input(
                    id: "repository", label: "限定仓库（可选）",
                    help: "选了就只能操作这个仓库；不选则每次调用自己指定仓库路径。",
                    kind: .path, target: .flag("--repository"), required: false
                ),
            ],
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/git", license: "MIT"
        ),
        // https://github.com/modelcontextprotocol/servers/tree/main/src/memory
        // README: MIT; repo relicensing to Apache-2.0. npm
        // @modelcontextprotocol/server-memory 2.0.0 (2026-10-19), engines node
        // >=24. MEMORY_FILE_PATH defaults to the package directory, which npx
        // may clear, so the user picks a folder.
        // Verified 2026-10-26: protocol 2025-06-18, 9 tools.
        MCPCatalogEntry(
            id: "memory", name: "Memory",
            summary: "官方参考服务器：把实体、关系和观察记录存成知识图谱，跨对话记住事情。",
            template: MCPServerConfig(
                id: "memory", name: "Memory", command: "npx",
                args: ["-y", "@modelcontextprotocol/server-memory@2.0.0"], risk: .write, origin: "catalog"
            ),
            runtime: .node, requirement: "Node.js 24+",
            inputs: [
                MCPCatalogEntry.Input(
                    id: "folder", label: "记忆文件所在文件夹",
                    help: "知识图谱保存为这个文件夹里的 memory.jsonl。",
                    kind: .path, target: .environmentFile("MEMORY_FILE_PATH", fileName: "memory.jsonl"), required: true
                ),
            ],
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/memory",
            license: "MIT / Apache-2.0"
        ),
        // https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking
        // README: MIT; repo relicensing to Apache-2.0. npm
        // @modelcontextprotocol/server-sequential-thinking 2.0.0 (2026-10-19),
        // engines node >=24. DISABLE_THOUGHT_LOGGING keeps thoughts out of the
        // stderr log. No side effects, hence `.read`.
        // Verified 2026-10-26: protocol 2025-06-18, 1 tool.
        MCPCatalogEntry(
            id: "sequential-thinking", name: "Sequential Thinking",
            summary: "官方参考服务器：让模型把复杂问题拆成可修改、可分支的思考步骤。不读写任何文件。",
            template: MCPServerConfig(
                id: "sequential-thinking", name: "Sequential Thinking", command: "npx",
                args: ["-y", "@modelcontextprotocol/server-sequential-thinking@2.0.0"],
                env: ["DISABLE_THOUGHT_LOGGING": "true"], risk: .read, origin: "catalog"
            ),
            runtime: .node, requirement: "Node.js 24+",
            homepage: "https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking",
            license: "MIT / Apache-2.0"
        ),
        // https://github.com/ChromeDevTools/chrome-devtools-mcp — Apache-2.0.
        // npm chrome-devtools-mcp 1.12.0 (2026-10-22), engines node ^20.19 ||
        // ^22.12 || >=23; needs Google Chrome. `--no-usage-statistics` is the
        // README's opt-out of Google's usage statistics.
        // Verified 2026-10-26: protocol 2025-06-18, 32 tools.
        MCPCatalogEntry(
            id: "chrome-devtools", name: "Chrome DevTools",
            summary: "Chrome 官方服务器：用 DevTools 操作和检查 Chrome，录制性能、看网络请求和控制台。已关闭使用统计上报。",
            template: MCPServerConfig(
                id: "chrome-devtools", name: "Chrome DevTools", command: "npx",
                args: ["-y", "chrome-devtools-mcp@1.12.0", "--no-usage-statistics"], risk: .execute, origin: "catalog"
            ),
            runtime: .node, requirement: "Node.js 20.19+，以及 Google Chrome",
            homepage: "https://github.com/ChromeDevTools/chrome-devtools-mcp", license: "Apache-2.0"
        ),
    ]
}
