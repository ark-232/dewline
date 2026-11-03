import AppKit
import Testing
@testable import Dewline

/// Pages from a table, never the network, counting what is asked.
private final class Pages: LinkPageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [URL] = []
    let pages: [URL: LinkPage]

    init(_ pages: [URL: LinkPage] = [:]) {
        self.pages = pages
    }

    var requests: [URL] { lock.withLock { asked } }

    func fetch(_ url: URL) async -> LinkPage? {
        lock.withLock { asked.append(url) }
        return pages[url]
    }
}

@MainActor
private struct Editor {
    let window: NSWindow
    let view: EditorTextView

    init(_ text: String, caret: Int, previews: LinkPreviews, height: CGFloat = 640) {
        let scrollView = EditorTextView.scrollView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.styler.cards.previews = previews
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
        window.layoutIfNeeded()
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
        view.textStorage!.attribute(key, at: index, effectiveRange: nil)
    }

    func picture(at index: Int) -> BlockPicture? {
        guard case .picture(let picture, _)? = (attribute(.dewlineBlock, at: index) as? BlockLine)?.role else { return nil }
        return picture
    }
}

/// A defaults domain and a cache folder of the test's own.
@MainActor
private final class Sandbox {
    let name = "dev.arkwerx.dewline.linkshost.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let folder = FileManager.default.temporaryDirectory.appending(path: "LinkPreviews-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    func previews(_ fetcher: Pages?) -> LinkPreviews {
        LinkPreviews(defaults: defaults, folder: folder, fetcher: fetcher)
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
}

private func picture(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Waits up to 2 s for `condition`, letting the main queue and tasks run.
@MainActor
private func until(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Suite struct LinkPreviewTests {
    @Test(arguments: [
        "https://example.com/page", "HTTP://EXAMPLE.COM", "https://dewline.arkwerx.com/docs/", "https://8.8.8.8/",
        "https://[2606:4700:4700::1111]/", "http://[::ffff:8.8.8.8]/",
    ])
    func previewsFetchPublicWebAddresses(_ address: String) throws {
        #expect(LinkPreviews.allows(try #require(URL(string: address))))
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x</b>", "ftp://example.com/", "mailto:a@example.com",
        "dewline://demo", "https://user:secret@example.com/", "https://user@example.com/",
        "http://localhost:3000/", "http://localhost./", "http://app.localhost/", "http://printer.local/", "http://router/",
        "http://127.0.0.1/", "http://127.1/", "http://0x7f000001/", "http://2130706433/", "http://0177.0.0.1/", "http://0.0.0.0/",
        "http://10.0.0.5/", "http://172.20.1.1/", "http://192.168.1.1/", "http://169.254.169.254/latest/meta-data/", "http://100.64.0.1/",
        "http://224.0.0.1/", "http://1.2.3.4.5/", "http://[::1]/", "http://[::]/", "http://[fe80::1]/", "http://[fd00::1]/",
        "http://[ff02::1]/", "http://[::ffff:127.0.0.1]/", "http://[::ffff:192.168.0.1]/", "http://[64:ff9b::a00:1]/",
    ])
    func previewsNeverFetchOtherSchemesOrLocalAddresses(_ address: String) throws {
        #expect(!LinkPreviews.allows(try #require(URL(string: address))))
    }

    @Test func aParagraphOfOneAddressIsACard() {
        #expect(LinkCards.url(ofParagraph: "https://example.com/a\n")?.absoluteString == "https://example.com/a")
        #expect(LinkCards.url(ofParagraph: "  <https://example.com/a>\n")?.absoluteString == "https://example.com/a")
        for text in ["See https://example.com", "https://a.com https://b.com", "[x](https://x.com)", "ftp://x.com", "https://", "example.com"] {
            #expect(LinkCards.url(ofParagraph: text) == nil, "\(text)")
        }
    }

    /// Links and wikilinks read in the note's ink with a thin accent underline, 45% in light and 60% in dark, and no fill.
    @Test func linksAreQuiet() throws {
        let sandbox = Sandbox()
        let text = "See [the docs](https://example.com/docs) and [[Field Notes]] here.\n"
        let editor = Editor(text, caret: (text as NSString).length, previews: sandbox.previews(Pages()))
        let store = ThemeStore.shared
        for index in [(text as NSString).range(of: "the docs").location, (text as NSString).range(of: "Field Notes").location] {
            #expect(editor.attribute(.foregroundColor, at: index) as? NSColor == store.color(.ink))
            #expect(editor.attribute(.underlineStyle, at: index) as? Int == NSUnderlineStyle.single.rawValue)
            #expect(editor.attribute(.backgroundColor, at: index) == nil)
            #expect(editor.attribute(.toolTip, at: index) as? String == "\u{2318}-click to open")
            let underline = try #require(editor.attribute(.underlineColor, at: index) as? NSColor)
            for (name, alpha) in [(NSAppearance.Name.aqua, 0.45), (.darkAqua, 0.6)] {
                let appearance = try #require(NSAppearance(named: name))
                let resolved = try #require(underline.resolved(for: appearance).usingColorSpace(.sRGB))
                let accent = try #require(store.color(.accent).resolved(for: appearance).usingColorSpace(.sRGB))
                #expect(abs(resolved.alphaComponent - alpha) < 0.01)
                #expect(abs(resolved.redComponent - accent.redComponent) < 0.01 && abs(resolved.greenComponent - accent.greenComponent) < 0.01)
            }
        }
        let plain = (text as NSString).range(of: "here").location
        #expect(editor.attribute(.underlineStyle, at: plain) as? Int ?? 0 == 0)
        #expect(editor.attribute(.toolTip, at: plain) == nil)
    }

    /// The card shows the host until the page arrives, then its title and picture; the caret in it shows the address;
    /// the address is fetched once however many cards show it, and the bytes never change.
    @Test func aBareAddressBecomesACardOnceItsPageArrives() async throws {
        let sandbox = Sandbox()
        let url = try #require(URL(string: "https://example.com/page"))
        let pages = Pages([url: LinkPage(title: "Example page", image: picture(width: 600, height: 314))])
        let text = "Intro\n\nhttps://example.com/page\n\nMiddle\n\n<https://example.com/page>\n\nEnd\n"
        let editor = Editor(text, caret: 0, previews: sandbox.previews(pages))
        let first = (text as NSString).range(of: "https://").location
        let second = (text as NSString).range(of: "<https").location
        let waiting = try #require(editor.picture(at: first))
        #expect(editor.picture(at: second) != nil)
        #expect((editor.attribute(.font, at: first) as! NSFont).pointSize < 1, "the address hides behind the card")
        await until { (editor.picture(at: first)?.size.height ?? 0) > waiting.size.height }
        let loaded = try #require(editor.picture(at: first))
        #expect(loaded.size.height > waiting.size.height, "the picture adds height")
        #expect(loaded.size.width == LinkCards.maxWidth)
        #expect(pages.requests == [url])
        #expect(editor.view.string == text)

        editor.place(first + 3)
        #expect(editor.picture(at: first) == nil)
        #expect((editor.attribute(.font, at: first) as! NSFont).pointSize > 1, "the caret shows the address")
        editor.place(0)
        #expect(editor.picture(at: first) != nil)
    }

    @Test func localAddressesStayLinksAndAreNeverFetched() async throws {
        let sandbox = Sandbox()
        let pages = Pages()
        let text = "http://localhost:8080/\n\nhttp://192.168.1.1/\n\nfile:///etc/hosts\n"
        let editor = Editor(text, caret: (text as NSString).length, previews: sandbox.previews(pages))
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.picture(at: 0) == nil && editor.picture(at: 24) == nil)
        #expect(pages.requests.isEmpty)
    }

    /// Off, there are no cards, no fetches and no cache on disk; on again, cards come back.
    @Test func theSwitchTurnsPreviewsOffAndDeletesTheCache() async throws {
        let sandbox = Sandbox()
        let url = try #require(URL(string: "https://example.com/a"))
        let pages = Pages([url: LinkPage(title: "A")])
        let previews = sandbox.previews(pages)
        let editor = Editor("Top\n\nhttps://example.com/a\n", caret: 0, previews: previews)
        await until { previews.cached(url)?.title == "A" }
        let file = try #require(previews.file(for: url))
        #expect(FileManager.default.fileExists(atPath: file.path))

        sandbox.defaults.set(false, forKey: LinkPreviews.defaultsKey)
        await until { !previews.isOn }
        #expect(!previews.isOn)
        #expect(editor.picture(at: 5) == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder.path))
        #expect(previews.metadata(for: url) == nil)
        #expect(pages.requests == [url])

        sandbox.defaults.set(true, forKey: LinkPreviews.defaultsKey)
        await until { editor.picture(at: 5) != nil }
        #expect(editor.picture(at: 5) != nil)
    }

    /// A page read once is kept on disk for 7 days, so the next session shows it without asking the site again.
    @Test func pagesAreCachedOnDiskForSevenDays() async throws {
        let sandbox = Sandbox()
        let url = try #require(URL(string: "https://example.com/kept"))
        let first = sandbox.previews(Pages([url: LinkPage(title: "Kept")]))
        #expect(first.metadata(for: url) == nil)
        await until { first.cached(url) != nil }
        let file = try #require(first.file(for: url))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(file.deletingLastPathComponent().lastPathComponent == sandbox.folder.lastPathComponent)
        #expect((attributes[.size] as? Int ?? 0) > 0)

        let offline = Pages()
        #expect(sandbox.previews(offline).metadata(for: url)?.title == "Kept")
        #expect(offline.requests.isEmpty)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 24 * 3600)], ofItemAtPath: file.path)
        let later = sandbox.previews(offline)
        #expect(later.metadata(for: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path), "an expired page is removed")
        await until { !offline.requests.isEmpty }
        #expect(offline.requests == [url])
        await until { later.cached(url) != nil }
        #expect(later.cached(url)?.isLoaded == false, "a failed fetch leaves the host alone")
    }
}

/// Draws a note with links offscreen, light and dark, to `DEWLINE_LINK_SHOTS`, with pages read from the plist at
/// `DEWLINE_LINK_PAGES` (address to page) in place of the network.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEWLINE_LINK_SHOTS"] != nil))
struct LinkShots {
    static let note = """
        # Reading list

        Links read as text with a thin underline. The [LinkPresentation docs](https://developer.apple.com/documentation/linkpresentation) explain the cards, and [[Field Notes]] links another note.

        A link on its own line becomes a card:

        https://github.com/ark-232/dewline

        https://www.apple.com/macos/

        A page that has not loaded shows its host:

        <https://example.com/not-loaded-yet>

        """

    @Test func drawLinks() async throws {
        let environment = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(environment["DEWLINE_LINK_SHOTS"]))
        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(environment["DEWLINE_LINK_PAGES"])))
        let table = try PropertyListDecoder().decode([String: LinkPage].self, from: data)
        let pages = Pages(Dictionary(uniqueKeysWithValues: table.map { (URL(string: $0.key)!, $0.value) }))
        let sandbox = Sandbox()
        let previews = sandbox.previews(pages)
        let editor = Editor(Self.note, caret: 0, previews: previews, height: 980)
        await until { pages.requests.count == 3 && previews.cached(URL(string: "https://www.apple.com/macos/")!) != nil }
        try await Task.sleep(for: .milliseconds(200))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            editor.window.appearance = NSAppearance(named: appearance)
            editor.view.styler.restyleDocument()
            editor.window.layoutIfNeeded()
            let view = try #require(editor.window.contentView)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: "after-\(name).png"))
        }
    }
}
