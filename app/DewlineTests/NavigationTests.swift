import AppKit
import Testing
@testable import Dewline

@Suite(.serialized) struct NavigationTests {
    private let a = URL(filePath: "/notes/a.md")
    private let b = URL(filePath: "/notes/b.md")
    private let c = URL(filePath: "/notes/c.md")

    @Test func historyGoesBackAndForwardToWhereEachFileWasLeft() {
        var history = History()
        #expect(!history.canGoBack && !history.canGoForward)
        history.visit(a, leaving: nil)
        let inA = Place(caret: 40, top: 12, offset: -3.5)
        history.visit(b, leaving: inA)
        #expect(history.canGoBack && !history.canGoForward)

        let inB = Place(caret: 7, top: 0, offset: 0)
        let back = history.back(leaving: inB)
        #expect(back == History.Entry(url: a, place: inA))
        #expect(!history.canGoBack && history.canGoForward)
        #expect(history.back(leaving: nil) == nil)

        let forward = history.forward(leaving: inA)
        #expect(forward == History.Entry(url: b, place: inB))

        // Opening a file from the middle drops what was forward of it.
        _ = history.back(leaving: inB)
        history.visit(c, leaving: inA)
        #expect(history.entries.map(\.url) == [a, c])
        #expect(!history.canGoForward)
    }

    @Test func historyKeepsTheLatestHundredEntries() {
        var history = History()
        for index in 0..<150 {
            history.visit(URL(filePath: "/notes/\(index).md"), leaving: nil)
        }
        #expect(history.entries.count == History.limit)
        #expect(history.entries.first?.url.lastPathComponent == "50.md")
        #expect(history.index == History.limit - 1)
    }

    @Test func sessionSurvivesDefaultsAndDecodesWhatItEncoded() throws {
        let suite = "dev.arkwerx.dewline.tests.session.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Session.load(from: defaults) == nil)

        let session = Session(windows: [
            Session.Window(folder: nil, tabs: [Session.Tab(path: "/tmp/loose.md", place: Place(caret: 3, top: 0, offset: 0))], selected: 0),
            Session.Window(folder: "/notes", tabs: [
                Session.Tab(path: "/notes/a.md", place: Place(caret: 120, top: 88, offset: -6.25)),
                Session.Tab(path: "/notes/Journal/today.md", place: Place(caret: 0, top: 0, offset: 0)),
            ], selected: 1),
            Session.Window(folder: "/empty", tabs: [], selected: 0),
        ])
        session.save(to: defaults)
        #expect(Session.load(from: defaults) == session)

        let json = try #require(defaults.data(forKey: Session.key))
        let decoded = try JSONDecoder().decode(Session.self, from: json)
        #expect(decoded.windows[1].tabs[0].place.offset == -6.25)
        #expect(decoded.windows[1].selected == 1)
    }

    /// Resumes a folder window of two tabs behind a window standing in for a file opened at launch.
    @Test @MainActor func resumeReadsOnlyTheSelectedTabAndOpensBehindTheFileOpenedAtLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, b) = (root.appending(path: "a.md"), root.appending(path: "b.md"))
        try Data("# A\n\nfirst\n".utf8).write(to: a)
        try Data("# B\n\nsecond\n".utf8).write(to: b)
        let inA = Place(caret: 6, top: 0, offset: 0)
        let session = Session(windows: [
            Session.Window(folder: root.path, tabs: [Session.Tab(path: a.path, place: inA), Session.Tab(path: b.path, place: Place(caret: 5, top: 0, offset: 0))], selected: 1),
        ])
        let front = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        front.isReleasedWhenClosed = false
        defer { front.close() }
        Offscreen.install()
        defer { Offscreen.uninstall() }

        MainWindowController.resume(session, behind: front)
        let documents = NSDocumentController.shared
        let second = try #require(documents.document(for: b)?.windowControllers.first as? MainWindowController)
        let tabs = second.tabs.tabs
        defer {
            for tab in tabs {
                tab.window?.orderOut(nil)
                if let document = tab.document as? NSDocument {
                    document.removeWindowController(tab)
                    documents.removeDocument(document)
                }
            }
        }
        #expect(documents.document(for: a) == nil)
        #expect(tabs.count == 2 && tabs[1] === second && tabs[0].document == nil)
        #expect(tabs.map(\.tabName) == ["a", "b"])
        #expect(second.textView?.selectedRange().location == 5)
        #expect(Offscreen.placed.contains { $0.window === second.window && $0.place == .below && $0.relativeTo == front.windowNumber })
        #expect(tabs[0].window?.isVisible == false)

        // The unread tab keeps its place in the session, and reads its file when selected.
        Offscreen.main = second.window
        let saved = try #require(MainWindowController.session().windows.first { $0.folder == root.path })
        #expect(saved.tabs.map(\.path) == [a.path, b.path] && saved.tabs[0].place == inA && saved.selected == 1)
        tabs[0].showWindow(nil)
        #expect(documents.document(for: a)?.windowControllers.first === tabs[0])
        #expect(tabs[0].textView?.selectedRange().location == 6)
    }

    /// A long note resumes at its place, measured on styled text, and stays there when the text past the first screen
    /// is styled after the window is up.
    @Test @MainActor func resumeKeepsALongNotesPlaceOnceItsTextIsStyled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "long.md")
        let text = (1...300).map { "## Section \($0)\n\nParagraph \($0) has **bold**, `code` and a [link](x.md), long enough to wrap once in a window this wide.\n\n- one\n- two\n" }.joined(separator: "\n")
        try Data(text.utf8).write(to: url)
        let target = (text as NSString).range(of: "Paragraph 200 has").location
        #expect(target > BlockMap.screen)
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let documents = NSDocumentController.shared
        func resume(at place: Place) async throws -> MainWindowController {
            MainWindowController.resume(Session(windows: [Session.Window(folder: nil, tabs: [Session.Tab(path: url.path, place: place)], selected: 0)]))
            let tab = try #require(documents.document(for: url)?.windowControllers.first as? MainWindowController)
            let textView = try #require(tab.textView)
            #expect(textView.styler.hasUnstyledText)
            for _ in 0..<300 where textView.styler.hasUnstyledText {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!textView.styler.hasUnstyledText)
            return tab
        }
        func close(_ tab: MainWindowController) {
            tab.window?.orderOut(nil)
            if let document = tab.document as? NSDocument {
                document.removeWindowController(tab)
                documents.removeDocument(document)
            }
        }

        let first = try await resume(at: Place(caret: 0, top: 0, offset: 0))
        first.textView?.setSelectedRange(NSRange(location: target + 4, length: 0))
        first.textView?.scrollRangeToVisible(NSRange(location: target, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        let place = try #require(first.place)
        #expect(place.top > BlockMap.screen && place.top < target)
        close(first)

        let second = try await resume(at: place)
        defer { close(second) }
        let resumed = try #require(second.place)
        #expect(resumed.caret == target + 4)
        #expect(resumed.top == place.top)
        #expect(abs(resumed.offset - place.offset) < 1)
    }

    /// The sidebar's island shows with the window's first frame, and its rows in a later one.
    @Test @MainActor func sidebarListsItsRowsAfterTheWindowsFirstFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Plan\n".utf8).write(to: root.appending(path: "plan.md"))
        Offscreen.install()
        defer { Offscreen.uninstall() }
        let controller = MainWindowController(folder: Folder(root))
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let outlines = all(window.contentView!).compactMap { $0 as? NSOutlineView }
        func lists(_ name: String) -> Bool {
            outlines.contains { list in
                (0..<list.numberOfRows).contains { row in
                    guard case .entry(let entry) = (list.item(atRow: row) as? SidebarNode)?.kind else { return false }
                    return entry.url.lastPathComponent == name
                }
            }
        }

        controller.showWindow(nil)
        #expect(!outlines.isEmpty && outlines.allSatisfy { $0.numberOfRows == 0 })
        for _ in 0..<200 where !lists("plan.md") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lists("plan.md"))
    }
}
