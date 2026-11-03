import AppKit
import MdCore
import Testing
@testable import Dewline

/// The main window as ux-v4 lays it out, built offscreen: the title, the tab row, the sidebar's folder row, the status
/// bar, the right pane's preview, Show Sidebar (B1) and restoring a place (B2).
@MainActor @Suite(.serialized)
struct ShellV4Tests {
    private static let type = "net.daringfireball.markdown"

    /// A folder "Field Notes" holding `files`, deleted when the test ends.
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "shell-v4-\(UUID().uuidString)/Field Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: root.appending(path: name)) }
        return root
    }

    /// `url` read into a document on its own change engine, as the app's are, without the shared store.
    private func document(_ url: URL) throws -> MarkdownDocument {
        let document = MarkdownDocument()
        document.engine = try ChangeEngine(store: url.deletingLastPathComponent().deletingLastPathComponent().appending(path: "store-\(UUID().uuidString)"))
        try document.read(from: url, ofType: Self.type)
        document.fileURL = url
        document.fileType = Self.type
        NSDocumentController.shared.addDocument(document)
        return document
    }

    private func close(_ controllers: [MainWindowController]) {
        for controller in controllers {
            if let document = controller.document as? NSDocument {
                document.removeWindowController(controller)
                NSDocumentController.shared.removeDocument(document)
            }
            controller.window?.isReleasedWhenClosed = false
            controller.window?.orderOut(nil)
        }
    }

    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    @Test func theTitleIsTheNoteAndTheSubtitleItsFolder() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["Launch plan.md": "# Launch plan\n\nShip it.\n", "Ideas.md": "# Ideas\n"])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "Launch plan.md")))
        main.showWindow(nil)
        Offscreen.main = main.window
        defer { close([main]) }
        await settle(0.5)
        let window = try #require(main.window)
        #expect(window.title == "Launch plan")
        #expect(window.subtitle == "Field Notes")
        #expect(window.toolbar?.items.map(\.itemIdentifier).contains(WindowToolbar.preview) == true)
        #expect(main.tabName == "Launch plan")
        #expect(main.statusBar.stateText == "Saved")
        #expect(main.statusBar.wordsText.hasSuffix("words"))
    }

    @Test func theTabRowShowsOnlyWithTwoTabs() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["a.md": "# A\n", "b.md": "# B\n"])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "a.md")))
        main.showWindow(nil)
        func row(_ controller: MainWindowController) -> TabRow? {
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            return all(controller.window!.contentView!).compactMap { $0 as? TabRow }.first
        }
        #expect(row(main)?.isHidden == true)
        let second = MainWindowController(folder: main.folder, joining: main)
        second.display(try document(root.appending(path: "b.md")))
        defer { close([main, second]) }
        await settle()
        #expect(row(main)?.isHidden == false && row(second)?.isHidden == false)
    }

    @Test func theSidebarListsTheTreeUnderTheFoldersOwnName() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["plan.md": "# Plan\n", "CLAUDE.md": "# Notes\n"])
        let main = MainWindowController(folder: Folder(root))
        main.showWindow(nil)
        defer { close([main]) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let outline = try #require(all(main.window!.contentView!).compactMap { $0 as? NSOutlineView }.first)
        for _ in 0..<200 where outline.numberOfRows < 3 { await settle(0.01) }
        let kinds = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNode)?.kind }
        guard case .root(let url)? = kinds.first else { Issue.record("The first row is not the folder"); return }
        #expect(url.lastPathComponent == "Field Notes")
        let names = kinds.compactMap { kind -> String? in
            if case .entry(let entry) = kind { return entry.url.lastPathComponent }
            if case .section(let title) = kind { return title }
            return nil
        }
        #expect(names == ["CLAUDE.md", "plan.md"])
    }

    @Test func showSidebarReachesTheSplitFromTheText() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["a.md": "# A\n\ntext\n"])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "a.md")))
        main.showWindow(nil)
        defer { close([main]) }
        let split = try #require(main.window?.contentViewController as? StationSplitController)
        let textView = try #require(main.textView)
        let item = NSMenuItem(title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "")
        #expect(NSApp.target(forAction: item.action!, to: nil, from: item) == nil || split.responds(to: item.action))
        #expect(split.validateUserInterfaceItem(item) && item.title == "Hide Sidebar")
        #expect(textView.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil))
        await settle(0.5)
        #expect(split.splitViewItems[0].isCollapsed)
    }

    @Test func aRestoredPlaceStaysPutAfterTheNextFrame() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let text = "# Long\n\n" + (1...240).map { "Paragraph \($0). " + String(repeating: "Words that wrap the line. ", count: 3) }.joined(separator: "\n\n") + "\n"
        let root = try folder(["long.md": text])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "long.md")))
        main.showWindow(nil)
        defer { close([main]) }
        await settle(0.5)
        let textView = try #require(main.textView)
        let target = (textView.string as NSString).range(of: "Paragraph 150.").location
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        textView.hold(target, at: 40)
        await settle(0.3)
        let saved = try #require(main.place)
        main.restore(saved)
        await settle(0.3)
        let after = try #require(main.place)
        #expect(after.top == saved.top)
        #expect(abs(after.offset - saved.offset) < 1)
    }

    @Test func previewShowsTheSourceBesideItAndPutsTheModeBack() async throws {
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let root = try folder(["a.md": "# A\n\nSome **bold** text.\n"])
        let main = MainWindowController(folder: Folder(root))
        main.display(try document(root.appending(path: "a.md")))
        main.showWindow(nil)
        defer { close([main]) }
        let textView = try #require(main.textView)
        #expect(!textView.styler.showsSource)
        main.togglePreview(nil)
        await settle(0.5)
        #expect(textView.styler.showsSource)
        #expect(main.pane.tab == .preview && main.pane.preview.textView.string == textView.string)
        #expect(!main.pane.preview.textView.isEditable && !main.pane.preview.textView.styler.showsSource)
        main.togglePreview(nil)
        #expect(!textView.styler.showsSource)
    }

    @Test func theStatusBarShowsOneMessageAtATime() {
        let bar = StatusBar()
        bar.post(.init(id: "loads", kind: .info, text: "Agents read 2 files here"))
        bar.post(.init(id: "update", kind: .question, text: "Check for updates once a day?"))
        #expect(bar.shown?.id == "update")
        bar.post(.init(id: "export", kind: .result, text: "Exported", untilTyping: true))
        #expect(bar.shown?.id == "export")
        bar.typed()
        #expect(bar.shown?.id == "update")
        bar.clear("update")
        #expect(bar.shown?.id == "loads")
    }

    @Test func quickOpenNamesANewNoteForWhatWasTyped() {
        #expect(QuickOpenPanel.noteName("plan") == "plan.md")
        #expect(QuickOpenPanel.noteName("a/b: c") == "a-b- c.md")
        #expect(QuickOpenPanel.noteName("Notes.md") == "Notes.md")
    }
}
