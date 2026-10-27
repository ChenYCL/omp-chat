#if os(macOS)
import SwiftUI
import OMPCore
import OMPDesign

/// 设置 → 环境: local environments per project, mirroring the official
/// `settings.localEnvironments` pane. The left column lists the repositories
/// the app knows (every conversation's working directory, resolved to its
/// repository root); the right side lists that project's own and inherited
/// environment files, lets one be selected, and opens a creator/editor that
/// writes the same TOML the official app writes.
///
/// Selection goes through the model (`selectLocalEnvironment`), and the
/// settings draft's copy is kept in sync through the `selections` binding so
/// a later whole-draft save cannot undo the choice.
struct LocalEnvironmentSettingsPane: View {
    @Environment(ChatAppModel.self) private var model
    @Binding var selections: [String: String]

    @State private var projectRoot: String?
    @State private var files: [LocalEnvironmentFile] = []
    @State private var loadedRoot: String?
    @State private var editing: Draft?
    @State private var deleting: LocalEnvironmentFile?
    @State private var failure: String?
    @State private var showingInherited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectPicker
            if let root = projectRoot {
                environmentList(root: root)
            } else {
                Text("还没有已绑定目录的对话。先把一个对话绑定到仓库，再在这里配置环境。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
            }
        }
        .task { reloadProjects(selectFirst: projectRoot == nil) }
        .alert("保存失败", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .sheet(item: $editing) { item in
            editorSheet(Binding(
                get: { editing ?? item },
                set: { editing = $0 }
            ))
        }
        .confirmationDialog(
            "删除环境「\(deleting?.displayName ?? "")」？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let file = deleting {
                    delete(file)
                }
                deleting = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: Projects

    private var projectPicker: some View {
        HStack(spacing: 8) {
            Text("项目")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.ompTextSecondary)
            Picker("项目", selection: $projectRoot) {
                ForEach(model.knownProjectRoots(), id: \.self) { root in
                    Text(GitInfo.tildified(root)).tag(Optional(root))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 380)
            Spacer()
            Button("新建环境") {
                guard let root = projectRoot else { return }
                editing = Draft.new(fileName: defaultFileName(root: root))
            }
            .disabled(projectRoot == nil)
            .accessibilityIdentifier("environmentCreate")
        }
    }

    private func defaultFileName(root: String) -> String {
        let taken = Set(files.map(\.fileName))
        let base = LocalEnvironmentDiscovery.defaultFileName
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("environment-\(index).toml") { index += 1 }
        return "environment-\(index).toml"
    }

    // MARK: Environments

    private func environmentList(root: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let own = files.filter { !$0.inherited }
            let inherited = files.filter(\.inherited)
            if own.isEmpty && inherited.isEmpty {
                Text("这个项目还没有本地环境。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.ompTextSecondary)
            }
            ForEach(own) { file in
                environmentRow(file)
            }
            if !inherited.isEmpty {
                Button {
                    showingInherited.toggle()
                } label: {
                    Label("继承的环境（\(inherited.count)）", systemImage: showingInherited ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ompTextSecondary)
                }
                .buttonStyle(.plain)
                if showingInherited {
                    ForEach(inherited) { file in
                        environmentRow(file)
                    }
                }
            }
        }
    }

    private func environmentRow(_ file: LocalEnvironmentFile) -> some View {
        HStack(spacing: 8) {
            let isSelected = isSelected(file)
            Button {
                choose(file)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12))
                    Text(file.displayName)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.ompText)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("environmentSelect.\(file.fileName)")

            Text(inheritedLabel(file))
                .font(.system(size: 11))
                .foregroundStyle(Color.ompTextTertiary)
                .lineLimit(1)

            if let error = file.parseError {
                Label("文件无效，保存将替换其内容", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(error.localizedDescription)
            }

            Spacer()

            Button("编辑") {
                openEditor(file)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityIdentifier("environmentEdit.\(file.fileName)")

            Button(role: .destructive) {
                deleting = file
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(file.inherited)
            .help(file.inherited ? "继承的环境在它自己的仓库里" : "删除")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.ompFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func inheritedLabel(_ file: LocalEnvironmentFile) -> String {
        guard file.inherited, let folder = file.sourceFolderName else { return file.fileName }
        return "来自 \(folder) · \(file.fileName)"
    }

    private func isSelected(_ file: LocalEnvironmentFile) -> Bool {
        guard let root = projectRoot else { return false }
        let chosen = model.selectedLocalEnvironmentPath(forProject: root)
        return chosen.map { LocalEnvironmentDiscovery.standardize($0) } == LocalEnvironmentDiscovery.standardize(file.path)
    }

    private func choose(_ file: LocalEnvironmentFile) {
        guard let root = projectRoot else { return }
        let alreadySelected = isSelected(file)
        // Selecting a selected row clears back to automatic; the sentinel
        // makes "no environment" explicit, matching the official `__none__`.
        model.selectLocalEnvironment(alreadySelected ? LocalEnvironmentDiscovery.noneSelection : file.path, forProject: root)
        syncSelectionDraft(root: root)
        reloadFiles(root: root)
    }

    private func delete(_ file: LocalEnvironmentFile) {
        if let failure = model.deleteLocalEnvironment(at: file.path) {
            self.failure = failure
            return
        }
        if let root = projectRoot {
            reloadFiles(root: root)
            syncSelectionDraft(root: root)
        }
    }

    /// Mirrors the model's stored selection into the settings draft, so a
    /// later save of the whole draft keeps this choice.
    private func syncSelectionDraft(root: String) {
        let key = LocalEnvironmentDiscovery.standardize(root)
        if let stored = model.settings.localEnvironmentSelections[key] {
            selections[key] = stored
        } else {
            selections.removeValue(forKey: key)
        }
    }

    private func reloadProjects(selectFirst: Bool) {
        let roots = model.knownProjectRoots()
        if selectFirst || projectRoot == nil || !roots.contains(projectRoot ?? "") {
            projectRoot = roots.first
        }
        if let root = projectRoot {
            reloadFiles(root: root)
        }
    }

    private func reloadFiles(root: String) {
        files = model.localEnvironments(forProject: root)
        loadedRoot = root
    }

    // MARK: Editor

    private func openEditor(_ file: LocalEnvironmentFile) {
        if let environment = file.environment {
            editing = Draft(existing: environment, fileName: file.fileName)
        } else {
            // An invalid file can be opened and saved over; the draft starts
            // empty and the row already warns that saving replaces it.
            editing = Draft.new(fileName: file.fileName)
        }
    }

    @ViewBuilder
    private func editorSheet(_ draft: Binding<Draft>) -> some View {
        NavigationStack {
            Form {
                if let original = editing, files.contains(where: { $0.fileName == original.fileName && $0.parseError != nil }) {
                    Section {
                        Label("这个环境文件无效。保存将替换其内容。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                    }
                }
                Section("基本信息") {
                    HStack {
                        Text("文件名")
                        Spacer()
                        TextField("environment.toml", text: Binding(
                            get: { draft.wrappedValue.fileName },
                            set: { draft.wrappedValue.fileName = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240)
                        .disabled(draft.wrappedValue.existing)
                    }
                    HStack {
                        Text("名称")
                        Spacer()
                        TextField("local", text: Binding(
                            get: { draft.wrappedValue.name },
                            set: { draft.wrappedValue.name = $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240)
                    }
                }
                scriptSection(title: "安装脚本（创建 Worktree 时运行）", script: draft.setup)
                scriptSection(title: "清理脚本（删除 Worktree 前运行）", script: draft.cleanup)
                actionsSection(draft)
                if !draft.wrappedValue.problems.isEmpty {
                    Section {
                        ForEach(draft.wrappedValue.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing?.existing == true ? "编辑环境" : "新建环境")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(draft.wrappedValue) }
                        .disabled(!draft.wrappedValue.problems.isEmpty)
                        .accessibilityIdentifier("environmentSave")
                }
            }
            .frame(minWidth: 560, minHeight: 520)
        }
    }

    private func scriptSection(title: String, script: Binding<Draft.Script>) -> some View {
        Section(title) {
            scriptField("默认", text: Binding(
                get: { script.wrappedValue.defaultScript },
                set: { script.wrappedValue.defaultScript = $0 }
            ))
            DisclosureGroup("平台覆盖") {
                ForEach(LocalEnvironmentPlatform.allCases, id: \.self) { platform in
                    scriptField(platform.displayName, text: Binding(
                        get: { script.wrappedValue.overrides[platform] ?? "" },
                        set: { script.wrappedValue.overrides[platform] = $0 }
                    ))
                }
                Text("没有覆盖的平台使用默认脚本。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ompTextTertiary)
            }
        }
    }

    private func scriptField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.ompTextSecondary)
            TextField("例如：npm install", text: text, axis: .vertical)
                .font(.system(size: 12).monospaced())
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func actionsSection(_ draft: Binding<Draft>) -> some View {
        Section {
            Text("这些动作可以运行任意命令，并显示在对话标题栏。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.ompTextTertiary)
            ForEach(draft.actions) { $action in
                actionRow($action, remove: {
                    draft.wrappedValue.actions.removeAll { $0.id == action.id }
                })
            }
            Button {
                draft.wrappedValue.actions.append(Draft.Action())
            } label: {
                Label("添加动作", systemImage: "plus")
            }
            .accessibilityIdentifier("environmentAddAction")
        } header: {
            Text("动作")
        }
    }

    private func actionRow(_ action: Binding<Draft.Action>, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("名称", text: action.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                Picker("图标", selection: action.icon) {
                    Text("工具").tag("tool")
                    Text("运行").tag("run")
                    Text("测试").tag("test")
                    Text("调试").tag("debug")
                }
                .frame(width: 100)
                Picker("平台", selection: action.platform) {
                    Text("全部平台").tag(String?.none)
                    ForEach(LocalEnvironmentPlatform.allCases, id: \.self) { platform in
                        Text(platform.displayName).tag(Optional(platform.rawValue))
                    }
                }
                .frame(width: 110)
                Button {
                    remove()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("删除动作")
            }
            TextField("命令", text: action.command, axis: .vertical)
                .font(.system(size: 12).monospaced())
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }

    private func save(_ draft: Draft) {
        guard let root = projectRoot else { return }
        let environment = draft.environment
        if let failure = model.saveLocalEnvironment(environment, toProject: root, fileName: draft.fileName) {
            self.failure = failure
            return
        }
        reloadFiles(root: root)
        syncSelectionDraft(root: root)
        editing = nil
    }
}

/// The editor's draft. Actions carry their own identity so the list can
/// animate; everything else maps one-to-one onto `LocalEnvironment`.
extension LocalEnvironmentSettingsPane {
    struct Draft: Identifiable {
        struct Script {
            var defaultScript = ""
            var overrides: [LocalEnvironmentPlatform: String] = [:]
        }

        struct Action: Identifiable {
            var id = UUID()
            var name = ""
            var icon = "tool"
            var command = ""
            var platform: String?
        }

        var id: String { fileName }
        var fileName: String
        var existing = false
        var name = ""
        var setup = Script()
        var cleanup = Script()
        var actions: [Action] = []

        static func new(fileName: String) -> Draft {
            Draft(fileName: fileName)
        }

        init(fileName: String) {
            self.fileName = fileName
        }

        init(existing environment: LocalEnvironment, fileName: String) {
            self.fileName = fileName
            self.existing = true
            name = environment.name
            setup = Script(script: environment.setup)
            if let cleanup = environment.cleanup {
                self.cleanup = Script(script: cleanup)
            }
            actions = environment.actions.map { action in
                Action(
                    name: action.name,
                    icon: action.icon ?? "tool",
                    command: action.command,
                    platform: action.platform
                )
            }
        }

        var environment: LocalEnvironment {
            LocalEnvironment(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                setup: setup.environment,
                cleanup: cleanup.isEmptyScript ? nil : cleanup.environment,
                actions: actions.map { action in
                    LocalEnvironmentAction(
                        name: action.name,
                        icon: action.icon,
                        command: action.command,
                        platform: action.platform
                    )
                }
            )
        }

        /// The official save blockers, straight from the environment model.
        var problems: [String] {
            environment.validationErrors()
        }
    }
}

extension LocalEnvironmentSettingsPane.Draft.Script {
    init(script: LocalEnvironmentScript) {
        self.init(defaultScript: script.script, overrides: script.overrides)
    }

    var isEmptyScript: Bool {
        defaultScript.isEmpty && overrides.values.allSatisfy(\.isEmpty)
    }

    var environment: LocalEnvironmentScript {
        LocalEnvironmentScript(script: defaultScript, overrides: overrides)
    }
}
#endif
