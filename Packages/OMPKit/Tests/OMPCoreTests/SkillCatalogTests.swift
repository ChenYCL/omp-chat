import XCTest
@testable import OMPCore

/// SKILL.md frontmatter as real skills write it, the duplicate rule, and the
/// size-capped list the model sees: a misread description hides a skill from
/// the model, a broken cap crowds out the rest of the prompt.
final class SkillCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func writeSkill(_ folder: String, _ contents: String, under base: URL? = nil) throws -> String {
        let directory = (base ?? root).appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("SKILL.md")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func front(_ contents: String, folder: String = "folder") throws -> SkillCatalog.Frontmatter {
        try SkillCatalog.frontmatter(contents, defaultName: folder)
    }

    private func failure(_ contents: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try front(contents)
            XCTFail("expected a parse failure", file: file, line: line)
            return nil
        } catch let error as SkillCatalog.SkillError {
            return error.message
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: Frontmatter

    func testQuotedValuesKeepColonsHashesAndEscapes() throws {
        let parsed = try front("""
        ---
        name: "deploy: prod"
        description: 'It''s for #release work: ship it'
        ---
        body
        """)
        XCTAssertEqual(parsed.name, "deploy: prod")
        XCTAssertEqual(parsed.description, "It's for #release work: ship it")

        let escaped = try front("---\nname: x\ndescription: \"tab\\there \\u4e2d \\\"q\\\"\"\n---\n")
        XCTAssertEqual(escaped.description, "tab here 中 \"q\"", "escapes resolve, then whitespace collapses to one line")
    }

    func testUnquotedProseWithColonIsTheWholeValue() throws {
        // Codex repairs these instead of failing the skill.
        let parsed = try front("---\nname: aws\ndescription: Build for AWS: ECS and EKS # deploy notes\n---\n")
        XCTAssertEqual(parsed.description, "Build for AWS: ECS and EKS", "a ' #' comment is dropped, the inner ': ' kept")
    }

    func testFoldedAndLiteralDescriptionsBecomeOneLine() throws {
        let folded = try front("""
        ---
        name: proto
        description: >
          Generate a prototype
          for the web.

          Use when asked.
        metadata:
          version: "2"
        ---
        """)
        XCTAssertEqual(folded.description, "Generate a prototype for the web. Use when asked.")

        let literal = try front("""
        ---
        name: emo
        description: |-
          第一行：保留冒号
            缩进的一行

          最后一行
        ---
        """)
        XCTAssertEqual(literal.description, "第一行：保留冒号 缩进的一行 最后一行")
    }

    func testPlainContinuationLinesFold() throws {
        let parsed = try front("---\nname: x\ndescription: first part\n  second part\nlicense: MIT\n---\n")
        XCTAssertEqual(parsed.description, "first part second part")
    }

    func testBOMAndCRLFAreAccepted() throws {
        let parsed = try front("\u{FEFF}---\r\nname: crlf\r\ndescription: >\r\n  windows\r\n  line endings\r\n---\r\nbody\r\n")
        XCTAssertEqual(parsed.name, "crlf")
        XCTAssertEqual(parsed.description, "windows line endings")
    }

    func testMissingNameFallsBackToFolderName() throws {
        XCTAssertEqual(try front("---\ndescription: d\n---\n", folder: "my-skill").name, "my-skill")
        XCTAssertEqual(try front("---\nname: \"  \"\ndescription: d\n---\n", folder: "blank").name, "blank")
        XCTAssertEqual(try front("---\nname: ~\ndescription: d\n---\n", folder: "null-name").name, "null-name")
    }

    func testInvalidFrontmatterIsRejectedWithAReason() {
        XCTAssertEqual(failure("no frontmatter here"), "缺少用 --- 包围的 YAML frontmatter")
        XCTAssertEqual(failure("---\nname: x\ndescription: never closed\n"), "缺少用 --- 包围的 YAML frontmatter")
        XCTAssertEqual(failure("---\n---\n"), "缺少用 --- 包围的 YAML frontmatter")
        XCTAssertEqual(failure("---\nname: x\n---\n"), "缺少 description")
        XCTAssertEqual(failure("---\nname: x\ndescription: \"\"\n---\n"), "缺少 description")
        XCTAssertEqual(failure("---\nname: \(String(repeating: "n", count: 65))\ndescription: d\n---\n"), "name 不能超过 64 个字符")
        XCTAssertEqual(failure("---\nname: 42\ndescription: d\n---\n"), "name 必须是字符串")
        XCTAssertEqual(failure("---\nname: [a, b]\ndescription: d\n---\n"), "name 必须是字符串")
        XCTAssertEqual(failure("---\nname: \"unterminated\ndescription: d\n---\n").map { $0.contains("引号没有闭合") }, true)
        XCTAssertEqual(failure("---\nname: x\ndescription:\n  nested: map\n---\n"), "description 必须是字符串")
        XCTAssertEqual(failure("---\nname: x\nname: y\ndescription: d\n---\n").map { $0.contains("重复") }, true)
    }

    func testSixtyFourCharacterNameIsAllowed() throws {
        let name = String(repeating: "a", count: 64)
        XCTAssertEqual(try front("---\nname: \(name)\ndescription: d\n---\n").name, name)
    }

    func testShortDescriptionComesFromMetadata() throws {
        let parsed = try front("---\nname: x\ndescription: long\nmetadata:\n  short-description: Short one\n  version: \"1\"\n---\n")
        XCTAssertEqual(parsed.shortDescription, "Short one")
    }

    // MARK: Catalog

    func testNearestRepositorySkillWinsOverRootAndUser() throws {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let service = repo.appendingPathComponent("services/api", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        let near = try writeSkill("deploy", "---\nname: deploy\ndescription: api deploy\n---\n", under: service.appendingPathComponent(".agents/skills"))
        let atRoot = try writeSkill("deploy", "---\nname: deploy\ndescription: repo deploy\n---\n", under: repo.appendingPathComponent(".agents/skills"))
        try writeSkill("lint", "---\nname: lint\ndescription: repo lint\n---\n", under: repo.appendingPathComponent(".agents/skills"))
        let home = root.appendingPathComponent("home", isDirectory: true)
        let userDeploy = try writeSkill("deploy", "---\nname: deploy\ndescription: user deploy\n---\n", under: home.appendingPathComponent(".agents/skills"))

        let repoRoots = SkillCatalog.repositoryRoots(workingDirectory: service.path)
        XCTAssertEqual(repoRoots.map(\.path).map { ($0 as NSString).standardizingPath }, [
            service.appendingPathComponent(".agents/skills").path,
            repo.appendingPathComponent(".agents/skills").path,
        ].map { ($0 as NSString).standardizingPath })

        let catalog = SkillCatalog.load(roots: repoRoots + [try XCTUnwrap(SkillCatalog.userRoot(home: home.path))])
        XCTAssertEqual(catalog.skills.map(\.name), ["deploy", "lint"])
        XCTAssertEqual(catalog.skills.first?.path, near)
        XCTAssertEqual(catalog.skills.first?.description, "api deploy")
        XCTAssertEqual(Set(catalog.shadowed.map(\.path)), [atRoot, userDeploy])
    }

    func testRepositoryRootsStopAtTheRepositoryAndWithoutOneUseOnlyTheFolder() throws {
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let repo = outer.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try writeSkill("above", "---\nname: above\ndescription: d\n---\n", under: outer.appendingPathComponent(".agents/skills"))
        try writeSkill("inside", "---\nname: inside\ndescription: d\n---\n", under: repo.appendingPathComponent(".agents/skills"))
        XCTAssertEqual(SkillCatalog.load(roots: SkillCatalog.repositoryRoots(workingDirectory: repo.path)).skills.map(\.name), ["inside"])

        let loose = root.appendingPathComponent("loose/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try writeSkill("parent", "---\nname: parent\ndescription: d\n---\n", under: root.appendingPathComponent("loose/.agents/skills"))
        XCTAssertTrue(SkillCatalog.repositoryRoots(workingDirectory: loose.path).isEmpty, "no repository: only the folder's own .agents/skills")
    }

    func testSameFileThroughTwoRootsIsListedOnceAndSymlinkedFoldersAreFollowed() throws {
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try writeSkill("tool", "---\nname: tool\ndescription: d\n---\n", under: shared)
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: skills.appendingPathComponent("tool").path, withDestinationPath: shared.appendingPathComponent("tool").path)
        try writeSkill(".hidden", "---\nname: hidden\ndescription: d\n---\n", under: skills)

        let catalog = SkillCatalog.load(roots: [SkillRoot(path: skills.path, scope: .user), SkillRoot(path: shared.path, scope: .user)])
        XCTAssertEqual(catalog.skills.map(\.name), ["tool"], "hidden folders are skipped; the symlinked copy is the same file")
        XCTAssertTrue(catalog.shadowed.isEmpty)
    }

    func testPluginSkillsAreNamespacedAndBrokenOnesReported() throws {
        let plugin = root.appendingPathComponent("plugin/skills", isDirectory: true)
        try writeSkill("search", "---\nname: search\ndescription: plugin search\n---\n", under: plugin)
        let broken = try writeSkill("broken", "---\nname: broken\n---\n", under: plugin)
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeSkill("search", "---\nname: search\ndescription: user search\n---\n", under: user)

        let catalog = SkillCatalog.load(roots: [SkillRoot(path: user.path, scope: .user), SkillRoot(path: plugin.path, scope: .plugin("sample"))])
        XCTAssertEqual(catalog.skills.map(\.name), ["search", "sample:search"], "a plugin skill never collides with a user one")
        XCTAssertEqual(catalog.problems, [SkillProblem(path: broken, reason: "缺少 description")])
    }

    func testExplicitOnlySkillIsNotOfferedToTheModel() throws {
        try writeSkill("manual", "---\nname: manual\ndescription: only when asked\n---\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manual/agents"), withIntermediateDirectories: true)
        try "policy:\n  allow_implicit_invocation: false\n".write(to: root.appendingPathComponent("manual/agents/openai.yaml"), atomically: true, encoding: .utf8)
        try writeSkill("auto", "---\nname: auto\ndescription: any time\n---\n")

        let catalog = SkillCatalog.load(roots: [SkillRoot(path: root.path, scope: .user)])
        XCTAssertEqual(catalog.skills.map(\.name), ["auto", "manual"])
        let section = try XCTUnwrap(catalog.promptSection())
        XCTAssertTrue(section.contains("- auto: any time (file: "))
        XCTAssertFalse(section.contains("manual"))
        XCTAssertFalse(catalog.readableRoots.contains { $0.hasSuffix("/manual") })
    }

    // MARK: Prompt budget

    private func skills(_ count: Int, description: String) -> [Skill] {
        (0..<count).map { index in
            Skill(name: "skill-\(index)", description: description, shortDescription: nil,
                  path: "/s/skill-\(index)/SKILL.md", scope: .user, allowsImplicitInvocation: true)
        }
    }

    private func listLines(_ section: String) -> [String] {
        section.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
    }

    func testEverythingFitsListsNameDescriptionAndPath() throws {
        let catalog = SkillCatalog(skills: skills(3, description: "does a thing"))
        let lines = listLines(try XCTUnwrap(catalog.promptSection()))
        XCTAssertEqual(lines, (0..<3).map { "- skill-\($0): does a thing (file: /s/skill-\($0)/SKILL.md)" })
    }

    func testOverBudgetShortensDescriptionsEvenlyBeforeDroppingSkills() throws {
        let description = String(repeating: "x", count: 200)
        let budget = SkillPromptBudget.characters(600)
        let lines = SkillCatalog.renderLines(skills(5, description: description), budget: budget)
        XCTAssertEqual(lines.count, 5, "every skill is still listed")
        XCTAssertFalse(lines.contains { $0.contains("未列出") })
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + budget.cost($1) }, 600)
        let lengths = lines.map { line -> Int in
            let afterName = line.split(separator: ":", maxSplits: 1)[1]
            return afterName.filter { $0 == "x" }.count
        }
        XCTAssertGreaterThan(lengths.min() ?? 0, 0)
        XCTAssertLessThanOrEqual((lengths.max() ?? 0) - (lengths.min() ?? 0), 1, "no skill takes the leftover budget")
    }

    func testFarOverBudgetOmitsTrailingSkillsWithACountedNote() throws {
        let budget = SkillPromptBudget.characters(300)
        let lines = SkillCatalog.renderLines(skills(40, description: "d"), budget: budget)
        let note = try XCTUnwrap(lines.last)
        let listed = lines.count - 1
        XCTAssertEqual(note, "- 还有 \(40 - listed) 个技能未列出（技能列表超出长度上限）。")
        XCTAssertGreaterThan(listed, 0)
        XCTAssertEqual(lines.dropLast(), ArraySlice((0..<listed).map { "- skill-\($0): (file: /s/skill-\($0)/SKILL.md)" }))
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + budget.cost($1) }, 300)
    }

    func testLongDescriptionIsCappedAtCodexLimit() throws {
        let catalog = SkillCatalog(skills: skills(1, description: String(repeating: "y", count: 2_000)))
        let line = try XCTUnwrap(listLines(try XCTUnwrap(catalog.promptSection(budget: .characters(100_000)))).first)
        XCTAssertTrue(line.contains(String(repeating: "y", count: 1_024) + "... (file:"))
        XCTAssertFalse(line.contains(String(repeating: "y", count: 1_025)))
    }

    func testBudgetFollowsTheContextWindow() {
        XCTAssertEqual(SkillPromptBudget.forContextWindow(nil), .characters(8_000))
        XCTAssertEqual(SkillPromptBudget.forContextWindow(0), .characters(8_000))
        XCTAssertEqual(SkillPromptBudget.forContextWindow(200_000), .tokens(4_000))
        // Tokens are counted as UTF-8 bytes / 4, so CJK descriptions cost more.
        XCTAssertEqual(SkillPromptBudget.tokens(10).cost("abc"), 1)
        XCTAssertEqual(SkillPromptBudget.tokens(10).cost("技能技能"), 4)
    }

    func testNoSkillsMeansNoSection() {
        XCTAssertNil(SkillCatalog().promptSection())
    }
}
