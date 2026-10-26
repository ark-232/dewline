import Foundation
import Testing
@testable import Dewline

struct ShellTests {
    @Test func gitIgnoreMatchesNamesAnchorsAndFolders() {
        let ignore = GitIgnore("# build output\nbuild/\n/drafts\n*.log\ndocs/private\n!keep.log\n")
        #expect(ignore.ignores("build", isFolder: true))
        #expect(ignore.ignores("notes/build", isFolder: true))
        #expect(!ignore.ignores("build", isFolder: false))
        #expect(ignore.ignores("drafts", isFolder: true))
        #expect(!ignore.ignores("notes/drafts", isFolder: true))
        #expect(ignore.ignores("notes/debug.log", isFolder: false))
        #expect(ignore.ignores("docs/private", isFolder: true))
        #expect(!ignore.ignores("private", isFolder: true))
        #expect(!ignore.ignores("notes.md", isFolder: false))
    }

    @Test func folderListsFoldersFirstInFinderOrderAndHidesNoise() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [".git", "node_modules", "build", "Journal"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in [".DS_Store", ".gitignore", "note 10.md", "note 2.md", "photo.png", "debug.log"] {
            try Data((file == ".gitignore" ? "build/\n*.log\n" : "").utf8).write(to: root.appending(path: file))
        }
        let folder = Folder(root)
        let listing = folder.children(of: folder.url)
        #expect(listing.entries.map(\.url.lastPathComponent) == ["Journal", "note 2.md", "note 10.md", "photo.png"])
        #expect(listing.entries.map(\.isMarkdown) == [false, true, true, false])
        #expect(listing.ignored == ["build/", "debug.log"])
        #expect(folder.relativePath(of: root.appending(path: "Journal/today.md")) == "Journal/today.md")
        #expect(folder.relativePath(of: root.deletingLastPathComponent()) == nil)
    }

    @Test func outlineKeepsH1ToH3WithLineNumbers() {
        let text = "# Plan\n\nIntro\n\n## **Before** the beta\n\n```\n# not a heading\n```\n\n#### Too deep\n### Monday\n"
        #expect(outline(of: text).map { [$0.level, $0.line] } == [[1, 1], [2, 5], [3, 12]])
        #expect(outline(of: text).map(\.title) == ["Plan", "Before the beta", "Monday"])
    }

    @Test func firstProseLineSkipsFrontMatterHeadingsAndMarkers() {
        #expect(firstProseLine(of: "---\ntitle: x\n---\n# Plan\n\n- [ ] Ship the **build** to [testers](t.md)\n") == "Ship the build to testers")
        #expect(firstProseLine(of: "# Only a title\n\n---\n") == "Only a title")
        #expect(firstProseLine(of: "> Quoted [[Wiki|alias]] `code`\n") == "Quoted Wiki code")
        #expect(firstProseLine(of: "\n\n") == nil)
    }

    @Test func shortDateNamesTodayYesterdayTheWeekThenTheDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 15)))
        func ago(_ days: Int, hour: Int = 9) -> Date {
            calendar.date(byAdding: .day, value: -days, to: calendar.date(bySettingHour: hour, minute: 12, second: 0, of: now)!)!
        }
        #expect(shortDate(ago(0), now: now, calendar: calendar) == "09:12")
        #expect(shortDate(ago(1, hour: 23), now: now, calendar: calendar) == "Yesterday")
        #expect(shortDate(ago(3), now: now, calendar: calendar) == "Thursday")
        #expect(shortDate(ago(7), now: now, calendar: calendar) == "18 Oct")
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 14, hour: 9)))
        #expect(shortDate(lastYear, now: now, calendar: calendar) == "14 Mar 2025")
    }

    @Test func visitsMoveToTheFrontWithoutDuplicates() {
        let a = Library.Visit(url: URL(filePath: "/a.md"), date: .distantPast)
        let b = Library.Visit(url: URL(filePath: "/b.md"), date: .distantPast)
        let again = Library.Visit(url: URL(filePath: "/a.md"), date: .now)
        #expect(Library.adding(again, to: [a, b], limit: 20) == [again, b])
        #expect(Library.adding(b, to: [a], limit: 1) == [b])
    }
}
