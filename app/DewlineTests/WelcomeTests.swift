import Foundation
import Testing
@testable import Dewline

/// The copy goes to a temporary folder, never ~/Documents.
struct WelcomeTests {
    @Test func theGuideIsBundledPlainAndComplete() throws {
        let text = try String(contentsOf: Welcome.bundled, encoding: .utf8)
        for section in ["## Headings", "## Emphasis", "## Lists", "## Tasks", "## Tables", "## Callouts", "## Wikilinks", "## Math", "## Diagrams", "## Watch a change land"] {
            #expect(text.contains(section), "\(section)")
        }
        #expect(text.contains("```mermaid"))
        #expect(!text.contains("—") && !text.contains(" -- "), "no dashes standing in for punctuation")
        #expect(text.split(separator: "\n").last == "Agents, git and sync apps write to the files you have open. Choose Help > Watch a Change Land (Demo). Dewline writes a short note into this file from outside the editor, the way an agent would, and you see it arrive below.")
    }

    @Test func copyMakesTheReadersOwnFileOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "Dewline")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let copy = try Welcome.copy(into: folder)
        #expect(copy == folder.appending(path: "Welcome.md"))
        #expect(try Data(contentsOf: copy) == Data(contentsOf: Welcome.bundled))
        try Data("# Mine\n".utf8).write(to: copy)
        #expect(try Welcome.copy(into: folder) == copy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "# Mine\n", "an existing copy keeps its edits")
    }

    @Test func demoWritesOneNoteAndKeepsTheReadersText() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try Welcome.copy(into: folder)
        let original = try String(contentsOf: copy, encoding: .utf8)
        try Welcome.writeDemo(to: copy)
        let once = try String(contentsOf: copy, encoding: .utf8)
        #expect(once.hasPrefix(original))
        #expect(once.dropFirst(original.count).hasPrefix("\n> [!note] Demo\n> Another app wrote this note"))
        try Welcome.writeDemo(to: copy)
        let twice = try String(contentsOf: copy, encoding: .utf8)
        #expect(twice.hasPrefix(original))
        #expect(twice.components(separatedBy: Welcome.demoLabel).count == 2, "a second run replaces the note")

        let bare = folder.appending(path: "bare.md")
        try Data("No newline".utf8).write(to: bare)
        try Welcome.writeDemo(to: bare)
        #expect(try String(contentsOf: bare, encoding: .utf8).hasPrefix("No newline\n\n> [!note] Demo\n"))
    }
}
