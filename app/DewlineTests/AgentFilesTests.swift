import Foundation
import MdCore
import Testing
@testable import Dewline

struct AgentFilesTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    @Test func findsTheFilesAgentsLoadAndSkipsTheRest() throws {
        let root = try folder([
            "CLAUDE.md": "# Rules\nBe brief.\n",
            "packages/web/AGENTS.md": "Use pnpm.",
            ".cursor/rules/style.mdc": "---\nalwaysApply: true\n---\n",
            ".claude/rules/testing.md": "Run the suite.\n",
            ".claude/projects/-repo/0b6c.jsonl": "{}\n",
            ".claude/settings.json": "{}",
            "node_modules/pkg/CLAUDE.md": "vendored\n",
            ".git/CLAUDE.md": "not a checkout\n",
            "README.md": "# Readme\n",
            "a/b/c/d/e/f/g/h/i/CLAUDE.md": "too deep\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AgentFile.find(in: root)
        let byPath = Dictionary(uniqueKeysWithValues: found.map { (String($0.url.path.dropFirst(root.standardizedFileURL.path.count + 1)), $0) })
        #expect(Set(byPath.keys) == [".claude/rules/testing.md", ".cursor/rules/style.mdc", "CLAUDE.md", "packages/web/AGENTS.md"])
        #expect(byPath.mapValues { $0.limit?.agent ?? "" } == [
            ".claude/rules/testing.md": "", ".cursor/rules/style.mdc": "Cursor", "CLAUDE.md": "Claude Code", "packages/web/AGENTS.md": "Codex",
        ])
        #expect(byPath["CLAUDE.md"]?.lines == 2 && byPath["CLAUDE.md"]?.bytes == 18)
        #expect(byPath["packages/web/AGENTS.md"]?.lines == 1, "a last line without a newline still counts")
        #expect(AgentFile.find(in: root, visits: 3).count < found.count, "the walk stops after its visits")
    }

    @Test func gaugeTakesTheFullerShareOfTheLimit() {
        let memory = AgentLimit(agent: "Claude Code", lines: 200, bytes: 25000)
        let url = URL(filePath: "/repo/MEMORY.md")
        let lines = AgentFile(url: url, contents: Data(String(repeating: "x\n", count: 150).utf8), limit: memory)
        #expect(lines.lines == 150 && lines.bytes == 300)
        #expect(lines.load == 0.75)
        let bytes = AgentFile(url: url, contents: Data(String(repeating: "x", count: 30000).utf8), limit: memory)
        #expect(bytes.load == 1.2)
        let none = AgentFile(url: url, contents: Data("x".utf8), limit: nil)
        #expect(none.load == nil)
        #expect(AgentFile(url: url, contents: Data(), limit: memory).load == 0)
    }

    @Test func tokensAreALocalEstimateOfFourBytesEach() {
        let url = URL(filePath: "/repo/AGENTS.md")
        func file(_ bytes: Int) -> AgentFile { AgentFile(url: url, contents: Data(repeating: 0x61, count: bytes), limit: nil) }
        #expect(file(0).estimatedTokens == 0)
        #expect(file(1).estimatedTokens == 1)
        #expect(file(8).estimatedTokens == 2)
        #expect(file(9).estimatedTokens == 3)
        #expect(file(3360).tokenLabel == "≈840 tok")
        #expect(file(12400).tokenLabel == "≈3.1k tok")
        #expect(file(480_000).tokenLabel == "≈120k tok")
        #expect(file(40).gaugeText(date: "2026-10-26") == "About 10 tokens, estimated here at four bytes a token.")
    }

    @Test func gaugeTextNamesTheAgentAndTheDocsDate() {
        let file = AgentFile(
            url: URL(filePath: "/repo/MEMORY.md"), contents: Data("a\nb\n".utf8),
            limit: AgentLimit(agent: "Claude Code", lines: 200, bytes: 250)
        )
        #expect(file.gaugeText(date: "2026-10-26")
            == "2 of 200 lines and 4 of 250 bytes that Claude Code loads, per its docs as of 2026-10-26. About 1 tokens, estimated here at four bytes a token.")
    }

    @Test func theEngineSuppliesTheDatedLimits() {
        #expect(agentFilesDate == "2026-10-26")
        #expect(agentLimit(for: URL(filePath: "/repo/AGENTS.md")) == AgentLimit(agent: "Codex", lines: nil, bytes: 32768))
        #expect(agentLimit(for: URL(filePath: "/repo/.claude/skills/pdf/SKILL.md")) == nil)
        #expect(isAgentFile(URL(filePath: "/repo/.claude/skills/pdf/SKILL.md")))
        #expect(!isAgentFile(URL(filePath: "/repo/README.md")))
    }

    @Test func onlyFoldersThatHoldAgentFilesCallForANewWalk() throws {
        let root = try folder([".claude/rules/a.md": "x\n", "logs/run.jsonl": "{}\n", "new/AGENTS.md": "x\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let known = [AgentFile(url: root.appending(path: ".claude/rules/a.md").standardizedFileURL, contents: Data(), limit: nil)]
        #expect(AgentFile.mayChange(known, in: [root.appending(path: ".claude")]))
        #expect(AgentFile.mayChange(known, in: [root]))
        #expect(!AgentFile.mayChange(known, in: [root.appending(path: "logs")]))
        #expect(AgentFile.mayChange(known, in: [root.appending(path: "new")]))
    }

    @Test func frontMatterShowsAsOneLine() {
        #expect(frontMatterLine(of: "---\nname: reviewer\ndescription: Reviews diffs\ntools:\n  - Read\n---\n# Body\n")
            == "name: reviewer · description: Reviews diffs · tools")
        #expect(frontMatterLine(of: "---\r\nalwaysApply: true\r\n---\r\n") == "alwaysApply: true")
        #expect(frontMatterLine(of: "# No front matter\n") == nil)
        #expect(frontMatterLine(of: "---\nname: unclosed\n") == nil)
        #expect(frontMatterLine(of: "---\n---\nbody") == nil)
    }
}
