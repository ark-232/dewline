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
        // Autosave waits for the choice too, and deciding the last conflict runs it again.
        #expect(await file.live.autosave() == .conflict)
        let id = try #require(file.live.changes.first { $0.value.conflict }?.key)
        file.live.decide(id, .keep)
        try await until { (try? String(contentsOf: file.url, encoding: .utf8)) == "# Plan\n\nShip on Monday.\n" }
    }

    @Test func aLateClaimMarksAQuietLanding() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        let after = "# Plan\n\nAgent note.\n"
        try Data(after.utf8).write(to: file.url)
        await file.live.refresh()
        #expect(file.textView.string == after)
        #expect(file.live.changes.values.allSatisfy { !$0.marked })
        let use = { (hash: String, declared: String?) in
            ControlSocket.Claim.ToolUse(id: "toolu_1", tool: .write, path: file.realpath, hash: hash, declared: declared)
        }
        file.claim(.preToolUse(use(Self.hex("# Plan\n"), Self.hex(after))))
        file.claim(.postToolUse(use(Self.hex(after), nil)))
        try await until { file.live.changes.values.contains { $0.marked && $0.origin == .agent(.claude, session: "s1") } }
    }

    @Test func aReleasedHoldSaves() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        file.claim(.preToolUse(.init(id: "toolu_1", tool: .read, path: file.realpath, hash: Self.hex("# Plan\n"), declared: nil)))
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        var refusal: ChangeEngine.Refusal?
        for _ in 0..<50 where refusal != .held {
            refusal = await file.live.autosave()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(refusal == .held)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n")
        file.claim(.turnEnd)
        try await until { (try? String(contentsOf: file.url, encoding: .utf8)) == "# Plan!\n" }
    }

    @Test func restoringASnapshotIsOneUndo() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        try Data("# Plan\n\nAgent note.\n".utf8).write(to: file.url)
        await file.live.refresh()
        try await until { !file.live.snapshots.isEmpty }
        let snapshots = file.live.snapshots
        let oldest = try #require(snapshots.last)
        #expect(snapshots.map(\.time) == snapshots.map(\.time).sorted(by: >))
        await file.live.restore(oldest)
        #expect(file.textView.string == "# Plan\n")
        // Restoring writes nothing to the file.
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan\n\nAgent note.\n")
        try await Task.sleep(for: .milliseconds(50))
        file.textView.undoManager?.undo()
        #expect(file.textView.string == "# Plan\n\nAgent note.\n")
    }

    @Test func pinningASnapshotShowsInTheList() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        try Data("# Plan\n\nAgent note.\n".utf8).write(to: file.url)
        await file.live.refresh()
        try await until { !file.live.snapshots.isEmpty }
        let snapshot = file.live.snapshots[0]
        file.live.pin(snapshot, true)
        try await until { file.live.snapshots.first { $0.time == snapshot.time && $0.origin == snapshot.origin }?.pinned == true }
    }

    @Test func aRenameSeenOnlyByTheWatchFollowsTheFile() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        let renamed = file.url.deletingLastPathComponent().appending(path: "renamed.md")
        try FileManager.default.moveItem(at: file.url, to: renamed)
        // The watch names the file by its realpath, under /private.
        try await until { file.live.url.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath() }
        #expect(file.document.fileURL == file.live.url)
        // Writes to the new name land.
        try Data("# Plan\n\nAgent note.\n".utf8).write(to: renamed)
        try await until { file.textView.string == "# Plan\n\nAgent note.\n" }
    }

    @Test func saveAsOntoTheSameFileGoesThroughTheEngine() async throws {
        let file = try OpenFile("# Plan\n")
        defer { file.close() }
        file.textView.insertText("!", replacementRange: NSRange(location: 6, length: 0))
        try await file.save(.saveAsOperation)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Plan!\n")
    }

    @Test func gitsLockReleaseLandsTheWaitingChange() async throws {
        let file = try OpenFile("# Plan\n", git: true)
        defer { file.close() }
        let lock = file.url.deletingLastPathComponent().appending(path: ".git/index.lock")
        try Data().write(to: lock)
        try Data("# Plan\n\nSwitched.\n".utf8).write(to: file.url)
        await file.live.refresh()
        #expect(file.textView.string == "# Plan\n")
        // The gitdir's watch lands it, well before the 1 s retry.
        try FileManager.default.removeItem(at: lock)
        try await until(within: .milliseconds(700)) { file.textView.string == "# Plan\n\nSwitched.\n" }
    }

    private static func hex(_ text: String) -> String {
        contentHash(Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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

    private func until(within limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
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

        init(_ text: String, git: Bool = false) throws {
            try self.init(Data(text.utf8), git: git)
        }

        /// With `git`, the file's folder is a new repository.
        init(_ bytes: Data, git: Bool = false) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "dewline-live-\(UUID().uuidString)")
            let files = folder.appending(path: "files")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            if git {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["init", "-q", files.path]
                process.environment = ["HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1"]
                try process.run()
                process.waitUntilExit()
            }
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

        /// The file's realpath, as hooks name it.
        var realpath: String {
            Darwin.realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
        }

        /// A Claude Code hook's claim in session s1, as `dewline notify` sends it.
        func claim(_ event: ControlSocket.Claim.Event) {
            LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: event), engine: document.engine!)
        }

        func location(of text: String) -> Int {
            (textView.string as NSString).range(of: text).location
        }

        /// Cmd-S.
        func save(_ operation: NSDocument.SaveOperationType = .saveOperation) async throws {
            let error: (any Error)? = await withCheckedContinuation { continuation in
                document.save(to: url, ofType: LiveFileTests.type, for: operation) { continuation.resume(returning: $0) }
            }
            if let error { throw error }
        }

        func close() {
            document.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
