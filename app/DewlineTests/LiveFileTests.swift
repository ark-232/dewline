import AppKit
import MdCore
import Testing
@testable import Dewline

/// Documents the change engine opens, each in a window that is never shown, with the engine's store in a temporary
/// folder.
@MainActor
struct LiveFileTests {
    private static let type = "net.daringfireball.markdown"

    @Test func anOutsideWriteLandsWithTheCaretKept() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        let caret = file.location(of: "Friday") + 2
        file.textView.setSelectedRange(NSRange(location: caret, length: 0))
        // Only the watch tells the document.
        try Data("Agent note.\n\n# Plan\n\nShip on Friday.\n".utf8).write(to: file.url)
        try await until { file.textView.string == "Agent note.\n\n# Plan\n\nShip on Friday.\n" }
        #expect(file.textView.selectedRange() == NSRange(location: caret + 13, length: 0))
        #expect(!file.document.isDocumentEdited)
        #expect(file.document.text == file.textView.string)
    }

    @Test func typingWhileAWriteLandsKeepsBoth() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        try Data("# Plan\n\nShip on Friday.\n\nAgent note.\n".utf8).write(to: file.url, options: .atomic)
        let landing = Task { await file.live.refresh() }
        // The landing reads the buffer before the keystroke, which moves the version under it.
        for _ in 0..<3 { await Task.yield() }
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        await landing.value
        #expect(file.textView.string == "# Plan!\n\nShip on Friday.\n\nAgent note.\n")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n\nShip on Friday.\n\nAgent note.\n")
    }

    @Test func anOverlappingWriteKeepsYourTextAndOpensAConflict() async throws {
        let file = try OpenFile("# Plan\n\nShip on Friday.\n")
        defer { file.close() }
        file.textView.insertText("Monday", replacementRange: NSRange(location: file.location(of: "Friday"), length: 6))
        try Data("# Plan\n\nShip on Sunday.\n".utf8).write(to: file.url)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan\n\nShip on Monday.\n")
        let conflict = try #require(file.live.changes.values.first { $0.conflict })
        #expect((file.textView.string as NSString).substring(with: conflict.range).contains("Monday"))
        // Cmd-S waits for the choice, and the other version stays on disk.
        await #expect(throws: SaveConflict.self) { try await file.save() }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n\nShip on Sunday.\n")
    }

    @Test func saveAfterAnOutsideWriteKeepsIt() async throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let file = try OpenFile(bom + Data("# Plan\n\nShip on Friday.\n".utf8))
        defer { file.close() }
        let end = file.location(of: "Friday.") + 7
        file.textView.insertText(" Then rest.", replacementRange: NSRange(location: end, length: 0))
        try (bom + Data("Agent note.\n\n# Plan\n\nShip on Friday.\n".utf8)).write(to: file.url)
        try await file.save()
        let both = "Agent note.\n\n# Plan\n\nShip on Friday. Then rest.\n"
        #expect(file.textView.string == both)
        #expect(try Data(contentsOf: file.url) == bom + Data(both.utf8))
        #expect(!file.document.isDocumentEdited)
    }

    @Test func autosaveWaitsForTheComposition() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        file.textView.setSelectedRange(NSRange(location: 6, length: 0))
        file.textView.insertText("!", replacementRange: file.textView.selectedRange())
        file.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await file.live.autosave() == .composing)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n")
        // The composition's end runs the refused autosave again.
        file.textView.unmarkText()
        try await until { (try? String(contentsOf: file.url, encoding: .utf8)) == "# Plan!に\n" }
        #expect(file.textView.string == "# Plan!に\n")
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private struct OpenFile {
        let folder: URL
        let url: URL
        let document: MarkdownDocument
        let textView: EditorTextView
        let live: LiveFile

        init(_ text: String) throws {
            try self.init(Data(text.utf8))
        }

        init(_ bytes: Data) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "dewline-live-\(UUID().uuidString)")
            let files = folder.appending(path: "files")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            url = files.appending(path: "plan.md")
            try bytes.write(to: url)
            document = MarkdownDocument()
            document.engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
            try document.read(from: url, ofType: LiveFileTests.type)
            // Without a fileURL the window leaves the recent files in user defaults alone.
            document.makeWindowControllers()
            textView = try #require(document.textView)
            live = try #require(document.live)
        }

        func location(of text: String) -> Int {
            (textView.string as NSString).range(of: text).location
        }

        /// Cmd-S.
        func save() async throws {
            let error: (any Error)? = await withCheckedContinuation { continuation in
                document.save(to: url, ofType: LiveFileTests.type, for: .saveOperation) { continuation.resume(returning: $0) }
            }
            if let error { throw error }
        }

        func close() {
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
