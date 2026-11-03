import AppKit
import MdCore
import Testing
@testable import Dewline

/// Draws the surfaces the app flows changed, offscreen, in light and dark, to PNGs for review. Runs only with
/// DEWLINE_FLOWS_SHOTS set to a folder (TEST_RUNNER_DEWLINE_FLOWS_SHOTS through xcodebuild); windows are never ordered
/// on screen.
@MainActor
@Suite(.serialized)
struct FlowsTests {
    private static let type = "net.daringfireball.markdown"

    @Test func drawTheChangedSurfaces() async throws {
        guard let path = ProcessInfo.processInfo.environment["DEWLINE_FLOWS_SHOTS"] else { return }
        let out = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-flows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appending(path: "Field Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let engine = try ChangeEngine(store: root.appending(path: "store"))
        let plan = "# Launch plan\n\nWe ship the beta to twelve testers on Friday.\n\nEach tester gets a build and a short survey.\n\n## Risks\n\nThe sync server is new and untested under load.\n\nNotes stay plain Markdown files on disk.\n"
        let revised = plan
            .replacingOccurrences(of: "twelve testers on Friday.", with: "twenty testers on Thursday.")
            .replacingOccurrences(of: "and a short survey.", with: "and a two-question survey.")
            .replacingOccurrences(of: "untested under load.", with: "untested under load, so we cap it at fifty sessions.")
        try Data(plan.utf8).write(to: notes.appending(path: "Launch plan.md"))
        try Data("# Groceries\n\nEggs.\n".utf8).write(to: notes.appending(path: "Groceries.md"))

        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: name))

            // The note with Claude's changes and the Keep bar.
            try Data(plan.utf8).write(to: notes.appending(path: "Launch plan.md"))
            let document = try Self.open(notes.appending(path: "Launch plan.md"), engine: engine)
            let controller = try #require(document.windowControllers.first as? MainWindowController)
            let window = try #require(controller.window)
            window.appearance = appearance
            try Self.claudeWrites(revised, over: plan, to: notes.appending(path: "Launch plan.md"), id: "toolu_\(suffix)", engine: engine)
            await Self.until { (document.live?.changes.values.count { $0.marked } ?? 0) == 3 }
            LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: .turnEnd), engine: engine)
            await Self.settle()
            try Self.save(Self.image(window), out, "keep-bar-\(suffix)")

            // The Changes tab beside it.
            let review = ReviewViewController(for: window)
            let pane = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            pane.appearance = appearance
            pane.backgroundColor = FlowColors.chrome
            pane.contentViewController = review
            pane.setContentSize(NSSize(width: 380, height: 300))
            review.reload()
            await Self.settle()
            try Self.save(Self.image(pane), out, "changes-tab-\(suffix)")

            // Earlier Versions.
            let versions = EarlierVersions(document, try #require(document.live))
            versions.sheet.appearance = appearance
            await versions.select(1)
            await Self.settle()
            try Self.save(Self.image(versions.sheet), out, "earlier-versions-\(suffix)")
            pane.close()
            document.close()

            // A conflict with git.
            let conflict = try await Self.conflict(in: root.appending(path: "git-\(suffix)"), appearance: appearance)
            try Self.save(Self.image(conflict.window), out, "conflict-\(suffix)")
            conflict.document.close()

            // The first launch's window.
            let welcome = root.appending(path: "Dewline-\(suffix)", directoryHint: .isDirectory)
            try Welcome.write(in: welcome)
            let first = AppDelegate.welcomeWindow(in: welcome)
            let firstWindow = try #require(first.window)
            firstWindow.appearance = appearance
            await Self.settle()
            try Self.save(Self.image(firstWindow), out, "welcome-\(suffix)")
            (first.document as? NSDocument)?.close()
        }
    }

    // MARK: Helpers

    private static func open(_ url: URL, engine: ChangeEngine) throws -> MarkdownDocument {
        let document = MarkdownDocument()
        document.engine = engine
        try document.read(from: url, ofType: type)
        document.makeWindowControllers()
        return document
    }

    /// You type in a paragraph while git rewrites it; the card opens under it.
    private static func conflict(in folder: URL, appearance: NSAppearance) async throws -> (document: MarkdownDocument, window: NSWindow) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "plan.md")
        let ours = "# Plan\n\nShip on Friday.\n\nTell the team.\n"
        try Data(ours.utf8).write(to: url)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path, "-c", "user.name=Flows", "-c", "user.email=flows@example.invalid"] + arguments
            process.environment = ["HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": "/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try git("add", "plan.md")
        try git("commit", "-q", "-m", "Friday")
        try git("checkout", "-q", "-b", "rewrite")
        try Data("# Plan\n\nShip on Sunday.\n\nTell the team.\n".utf8).write(to: url)
        try git("commit", "-q", "-am", "Sunday")
        try git("checkout", "-q", "-")
        let engine = try ChangeEngine(store: folder.appending(path: ".store"))
        let document = try open(url, engine: engine)
        let controller = try #require(document.windowControllers.first as? MainWindowController)
        let window = try #require(controller.window)
        window.appearance = appearance
        let textView = try #require(controller.textView)
        textView.insertText("Monday", replacementRange: ((textView.string as NSString).range(of: "Friday")))
        try git("checkout", "-q", "rewrite")
        await until { document.live?.changes.values.contains(where: \.conflict) == true }
        await settle()
        return (document, window)
    }

    private static func claudeWrites(_ after: String, over before: String, to url: URL, id: String, engine: ChangeEngine) throws {
        let path = Darwin.realpath(url.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? url.path
        func hex(_ text: String) -> String { contentHash(Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        func use(_ hash: String, _ declared: String?) -> ControlSocket.Claim.ToolUse {
            ControlSocket.Claim.ToolUse(id: id, tool: .edit, path: path, hash: hash, declared: declared)
        }
        LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: .preToolUse(use(hex(before), hex(after)))), engine: engine)
        try Data(after.utf8).write(to: url, options: .atomic)
        LiveFile.claim(ControlSocket.Claim(vendor: .claude, session: "s1", event: .postToolUse(use(hex(after), nil))), engine: engine)
    }

    /// The window with its title bar, drawn offscreen.
    private static func image(_ window: NSWindow) -> NSBitmapImageRep {
        window.contentView?.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let view = window.contentView?.superview ?? window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        (window.appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        return rep
    }

    private static func save(_ rep: NSBitmapImageRep, _ folder: URL, _ name: String) throws {
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appending(path: name + ".png"))
    }

    private static func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func until(_ seconds: Double = 6, _ condition: () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition(), Date.now < deadline { await settle(0.05) }
    }
}
