import Foundation
import Testing
@testable import Dewline

struct NavigationTests {
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

    @Test func breadcrumbsRunFromTheFolderDownToTheFile() {
        let root = URL(filePath: "/Users/me/notes", directoryHint: .isDirectory)
        let file = URL(filePath: "/Users/me/notes/Projects/2026/plan.md")
        #expect(breadcrumbs(of: file, in: root).map(\.path) == [
            "/Users/me/notes", "/Users/me/notes/Projects", "/Users/me/notes/Projects/2026", "/Users/me/notes/Projects/2026/plan.md",
        ])
        #expect(breadcrumbs(of: URL(filePath: "/Users/me/notes/top.md"), in: root).map(\.path) == ["/Users/me/notes", "/Users/me/notes/top.md"])
        #expect(breadcrumbs(of: URL(filePath: "/tmp/loose.md"), in: root).map(\.path) == ["/tmp", "/tmp/loose.md"])
        #expect(breadcrumbs(of: file, in: nil).map(\.path) == ["/Users/me/notes/Projects/2026", "/Users/me/notes/Projects/2026/plan.md"])
        #expect(breadcrumbs(of: nil, in: root).map(\.path) == ["/Users/me/notes"])
        #expect(breadcrumbs(of: URL(filePath: "/Users/me/notesbook/x.md"), in: root).map(\.path) == ["/Users/me/notesbook", "/Users/me/notesbook/x.md"])
    }
}
