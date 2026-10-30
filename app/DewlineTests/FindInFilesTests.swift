import AppKit
import MdCore
import Testing
@testable import Dewline

@MainActor
struct FindInFilesTests {
    /// Writes each file's text into a new folder and returns their URLs in the order given.
    private func folder(_ files: [(name: String, text: String)]) throws -> (root: URL, urls: [URL]) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).standardizedFileURL
        let urls = try files.map { file in
            let url = root.appending(path: file.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: url)
            return url
        }
        return (root, urls)
    }

    private func finished(_ search: FileSearch) async {
        for _ in 0..<1000 where search.isSearching {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func resultsArriveBatchByBatchInTheOrderSearched() async throws {
        let (root, urls) = try folder([("a.md", "plan\nPlan"), ("b.md", "nothing"), ("c.md", "the plan")])
        defer { try? FileManager.default.removeItem(at: root) }
        let search = FileSearch(batch: 1)
        var replaced: [Bool] = []
        search.changed = { replaced.append($0) }
        search.search("plan", options: SearchOptions(), in: urls, after: .zero)
        #expect(search.isSearching)
        await finished(search)
        #expect(search.results.map(\.url) == [urls[0], urls[2]])
        #expect(search.results.map { $0.matches.map(\.line) } == [[1, 2], [1]])
        #expect(search.matchCount == 3 && !search.stopped)
        // The first batch replaces the results, the third adds c.md, and the end updates the count.
        #expect(replaced == [true, false, false])

        search.search("Plan", options: SearchOptions(matchCase: true, wholeWord: true), in: urls, after: .zero)
        await finished(search)
        #expect(search.results.map { $0.matches.map(\.range) } == [[NSRange(location: 5, length: 4)]])
    }

    @Test func theLimitStopsTheSearchAndSaysSo() async throws {
        let (root, urls) = try folder([("a.md", "plan plan"), ("b.md", "plan"), ("c.md", "plan")])
        defer { try? FileManager.default.removeItem(at: root) }
        let search = FileSearch(limit: 2, batch: 1)
        search.search("plan", options: SearchOptions(), in: urls, after: .zero)
        await finished(search)
        #expect(search.matchCount == 2 && search.stopped)
        #expect(search.results.map(\.url) == [urls[0]])

        let all = FileSearch(limit: 4, batch: 1)
        all.search("plan", options: SearchOptions(), in: urls, after: .zero)
        await finished(all)
        #expect(all.matchCount == 4 && !all.stopped)
    }

    @Test func aSearchWaitsAndAKeyBeforeItRunsCancelsIt() async throws {
        let (root, urls) = try folder([("alpha.md", "alpha"), ("beta.md", "beta")])
        defer { try? FileManager.default.removeItem(at: root) }
        let search = FileSearch()
        var shown: [[URL]] = []
        search.changed = { _ in shown.append(search.results.map(\.url)) }
        let clock = ContinuousClock()
        let start = clock.now
        search.search("alpha", options: SearchOptions(), in: urls)
        search.search("beta", options: SearchOptions(), in: urls)
        await finished(search)
        #expect(clock.now - start >= .milliseconds(150))
        #expect(!shown.isEmpty && shown.allSatisfy { $0 == [urls[1]] })
    }

    @Test func aNewSearchCancelsTheOneInFlight() async throws {
        let files = (0..<40).map { (name: "alpha \($0).md", text: "alpha") } + [(name: "beta.md", text: "beta")]
        let (root, urls) = try folder(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = FileSearch(batch: 1)
        var typed = false
        var shownAfter: [[String]] = []
        search.changed = { _ in
            if typed {
                shownAfter.append(search.results.map(\.url.lastPathComponent))
            } else {
                // A key arrives between the first search's batches.
                typed = true
                search.search("beta", options: SearchOptions(), in: urls, after: .zero)
            }
        }
        search.search("alpha", options: SearchOptions(), in: urls, after: .zero)
        await finished(search)
        #expect(typed && !shownAfter.isEmpty)
        #expect(shownAfter.allSatisfy { $0.allSatisfy { $0 == "beta.md" } }, "\(shownAfter)")
        #expect(search.results.map(\.url.lastPathComponent) == ["beta.md"])
    }

    @Test func anEmptyQueryClearsAtOnce() async throws {
        let (root, urls) = try folder([("a.md", "plan")])
        defer { try? FileManager.default.removeItem(at: root) }
        let search = FileSearch()
        search.search("plan", options: SearchOptions(), in: urls, after: .zero)
        await finished(search)
        #expect(search.matchCount == 1)
        var replaced: [Bool] = []
        search.changed = { replaced.append($0) }
        search.search("", options: SearchOptions(), in: urls)
        #expect(search.results.isEmpty && search.matchCount == 0 && !search.isSearching)
        #expect(replaced == [true])
    }

    /// Drives the sidebar in a window that is never shown.
    @Test func theSidebarSearchesAndEscapeOrClearingReturnsToTheTree() async throws {
        let (root, _) = try folder([("notes/a.md", "# Plan\nThe plan"), ("b.md", "nothing")])
        defer { try? FileManager.default.removeItem(at: root) }
        let window = try #require(MainWindowController(folder: Folder(root)).window)
        func visible<T: NSView>(_ type: T.Type) -> [T] {
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            return all(window.contentView!).compactMap { $0 as? T }.filter { !$0.isHiddenOrHasHiddenAncestor }
        }
        let tree = try #require(visible(NSOutlineView.self).first)
        #expect(visible(NSSearchField.self).isEmpty)
        let sidebar = try #require((window.contentViewController as? NSSplitViewController)?.splitViewItems.first)
        sidebar.isCollapsed = true

        NSApp.sendAction(#selector(MainWindowController.findInFiles(_:)), to: window.windowController, from: nil)
        #expect(!sidebar.isCollapsed)
        let editor = try #require(window.firstResponder as? NSTextView)
        let field = try #require(visible(NSSearchField.self).first)
        #expect(editor.delegate === field && tree.isHiddenOrHasHiddenAncestor)
        editor.insertText("plan", replacementRange: editor.selectedRange())
        let results = try #require(visible(NSOutlineView.self).first)
        for _ in 0..<300 where results.numberOfRows < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(results.numberOfRows == 3)
        let line = try #require(results.view(atColumn: 0, row: 1, makeIfNecessary: true))
        #expect(line.accessibilityLabel() == "Line 1: # Plan")
        #expect(results.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityLabel() == "a.md, notes, 2 matches")

        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!tree.isHiddenOrHasHiddenAncestor && results.isHiddenOrHasHiddenAncestor)
        #expect(field.stringValue == "plan")

        NSApp.sendAction(#selector(MainWindowController.findInFiles(_:)), to: window.windowController, from: nil)
        #expect(tree.isHiddenOrHasHiddenAncestor)
        let clear = try #require((field.cell as? NSSearchFieldCell)?.cancelButtonCell)
        NSApp.sendAction(try #require(clear.action), to: clear.target, from: clear)
        #expect(!tree.isHiddenOrHasHiddenAncestor && field.stringValue.isEmpty)
    }

    @Test func findInFilesNeedsAFolder() throws {
        let edit = try #require(NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let item = try #require(edit.item(withTitle: "Find")?.submenu?.item(withTitle: "Find in Files…"))
        #expect(item.action == #selector(MainWindowController.findInFiles(_:)))
        #expect(KeyEquivalent(item.keyEquivalent, item.keyEquivalentModifierMask).glyphs == "⇧⌘F")
        let (root, _) = try folder([("a.md", "")])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!MainWindowController(folder: nil).validateMenuItem(item))
        #expect(MainWindowController(folder: Folder(root)).validateMenuItem(item))
    }

    @Test func aThousandFilesStreamResults() async throws {
        let paragraph = String(repeating: "The launch plan moves to Friday after the beta. ", count: 40)
        let files = (0..<1000).map { (name: "area \($0 / 100)/note \($0).md", text: $0 % 50 == 0 ? paragraph + "needle" : paragraph) }
        let (root, urls) = try folder(files)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = FileSearch()
        let clock = ContinuousClock()
        let start = clock.now
        var first: Duration?
        search.changed = { _ in if first == nil, !search.results.isEmpty { first = clock.now - start } }
        search.search("needle", options: SearchOptions(), in: urls, after: .zero)
        await finished(search)
        let total = clock.now - start
        print("Find in Files: 1,000 files of \(paragraph.utf8.count.formatted()) bytes, first match in \(first ?? .zero), all in \(total)")
        #expect(search.matchCount == 20)
        #expect(total < .seconds(5))
    }
}
