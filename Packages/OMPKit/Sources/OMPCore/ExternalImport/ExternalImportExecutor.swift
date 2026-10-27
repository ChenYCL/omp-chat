import Foundation

/// Runs the selected entries of a scan against injected roots. The only side
/// effects are file writes inside `environment.skillsRoot` and the project
/// folders named by selected AGENTS.md rows; everything that lands in
/// OMPChat's own settings, store or vault comes back in `Outcome` for the
/// app model to apply.
public enum ExternalImportExecutor {

    public struct MCPSecret: Equatable, Sendable {
        public var serverID: String
        public var variable: String
        public var value: String

        public init(serverID: String, variable: String, value: String) {
            self.serverID = serverID
            self.variable = variable
            self.value = value
        }
    }

    /// Everything the model has to apply to its own state.
    public struct Outcome: Sendable {
        public var instructionsBlocks: [String] = []
        /// Servers to add, env values still filled (the model vaults them).
        public var mcpServers: [MCPServerConfig] = []
        public var mcpSecrets: [MCPSecret] = []
        public var conversations: [Conversation] = []
        public var newProjects: [Project] = []
        public var skillsCopied: [String] = []
        public var agentsMDWritten: [String] = []
        /// Claude Code plugin roots to stage and install via the model's
        /// plugin store; per-plugin results are reported by the model.
        public var pluginFolders: [(id: String, name: String, folder: String)] = []

        public init() {}
    }

    /// Runs the selection. `environment.projectIDByName` lets imported
    /// sessions reuse existing same-name projects.
    public static func run(
        selection: ExternalImportSelection,
        scan: ExternalImportScan,
        environment: ExternalImportScanner.Environment
    ) -> (report: ExternalImportReport, outcome: Outcome) {
        var outcome = Outcome()
        var lines: [ExternalImportReport.Line] = []
        var projectIDByName = environment.projectIDByName
        var newProjects: [Project] = []
        var sessionsSelected = false

        for entry in scan.entries where selection.contains(entry) {
            switch entry.operation {
            case .appendInstructions(_, let block):
                outcome.instructionsBlocks.append(block)
                lines.append(ExternalImportReport.imported(entry))
            case .writeAgentsMD(let projectRoot, let sourceName, let body):
                let target = (projectRoot as NSString).appendingPathComponent(AgentsMDLoader.fileName)
                if FileManager.default.fileExists(atPath: target) {
                    lines.append(ExternalImportReport.skipped(entry, "项目已有 \(AgentsMDLoader.fileName)，不会覆盖或合并"))
                    continue
                }
                let provenance = "<!-- 从 \(sourceName) 导入；源文件没有改动。 -->\n\n"
                guard FileManager.default.createFile(atPath: target, contents: Data((provenance + body).utf8)) else {
                    lines.append(ExternalImportReport.failed(entry, "无法写入 \(target)"))
                    continue
                }
                outcome.agentsMDWritten.append(target)
                lines.append(ExternalImportReport.imported(entry))
            case .addMCPServer(let server):
                outcome.mcpServers.append(server)
                for (variable, value) in server.env where !value.isEmpty {
                    outcome.mcpSecrets.append(MCPSecret(serverID: server.id, variable: variable, value: value))
                }
                lines.append(ExternalImportReport.imported(entry))
            case .copySkill(let sourceFolder, let name):
                let target = (environment.skillsRoot as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target) {
                    lines.append(ExternalImportReport.skipped(entry, "技能「\(name)」已存在，跳过"))
                    continue
                }
                // A source entry may be a symlink to the real skill.
                let real = PluginPath.real(sourceFolder)
                do {
                    try PluginStore.checkContainment(root: real)
                    try FileManager.default.createDirectory(atPath: environment.skillsRoot, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(atPath: real, toPath: target)
                    outcome.skillsCopied.append(name)
                    lines.append(ExternalImportReport.imported(entry))
                } catch {
                    lines.append(ExternalImportReport.failed(entry, "复制技能失败：\(error.localizedDescription)"))
                }
            case .importSession(let session):
                sessionsSelected = true
                let conversation = makeConversation(from: session, projectIDByName: &projectIDByName, newProjects: &newProjects)
                outcome.conversations.append(conversation)
                lines.append(ExternalImportReport.imported(entry))
            case .createProjectGroup:
                // Groups are derived from the imported sessions themselves;
                // the row only records intent.
                continue
            case .installPlugin(let folder, let name):
                outcome.pluginFolders.append((entry.id, name, folder))
                // The model appends the real result line after staging.
            case nil:
                lines.append(ExternalImportReport.skipped(entry, entry.skippedReason ?? "不可导入"))
            }
        }

        if scan.entries.contains(where: { $0.kind == .projects && selection.contains($0) }) {
            let row = scan.entries.first { $0.kind == .projects && selection.contains($0) }!
            if sessionsSelected {
                lines.append(.init(
                    id: row.id, provider: row.provider, kind: .projects, title: "项目分组",
                    note: "导入的会话已按原文件夹归入项目", failed: false
                ))
            } else {
                lines.append(.init(
                    id: row.id, provider: row.provider, kind: .projects, title: "项目分组",
                    note: "没有选择会话，没有要创建的项目分组", failed: false
                ))
            }
        }

        outcome.newProjects = newProjects
        // Skipped rows keep their scan reasons so the report explains them.
        for entry in scan.entries where !selection.contains(entry) && !entry.isAvailable {
            lines.append(ExternalImportReport.skipped(entry, entry.skippedReason ?? ""))
        }
        return (ExternalImportReport(lines: lines), outcome)
    }

    static func makeConversation(
        from session: ExternalImportSession,
        projectIDByName: inout [String: UUID],
        newProjects: inout [Project]
    ) -> Conversation {
        var projectID: UUID?
        if let folder = session.projectFolderName {
            if let existing = projectIDByName[folder] {
                projectID = existing
            } else {
                let project = Project(name: folder)
                projectIDByName[folder] = project.id
                newProjects.append(project)
                projectID = project.id
            }
        }
        let start = session.createdAt ?? Date()
        let end = session.updatedAt ?? start
        let count = max(1, session.messages.count)
        let step = session.messages.count > 1 ? end.timeIntervalSince(start) / Double(count - 1) : 0
        let messages = session.messages.enumerated().map { index, message in
            ChatMessage(
                role: message.role == "user" ? .user : .assistant,
                parts: [.text(message.text)],
                status: .complete,
                createdAt: start.addingTimeInterval(step * Double(index))
            )
        }
        var conversation = Conversation(
            title: session.title,
            messages: messages,
            createdAt: start,
            updatedAt: end,
            projectID: projectID,
            workingDirectory: session.workingDirectory
        )
        conversation.importedFrom = session.key
        return conversation
    }
}

extension ExternalImportReport {
    static func imported(_ entry: ExternalImportEntry) -> ExternalImportReport.Line {
        .init(id: entry.id, provider: entry.provider, kind: entry.kind, title: entry.title, note: nil, failed: false)
    }

    static func skipped(_ entry: ExternalImportEntry, _ reason: String) -> ExternalImportReport.Line {
        .init(id: entry.id, provider: entry.provider, kind: entry.kind, title: entry.title, note: reason, failed: false)
    }

    static func failed(_ entry: ExternalImportEntry, _ reason: String) -> ExternalImportReport.Line {
        .init(id: entry.id, provider: entry.provider, kind: entry.kind, title: entry.title, note: reason, failed: true)
    }
}
