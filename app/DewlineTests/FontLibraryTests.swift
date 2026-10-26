import AppKit
import CoreText
import Testing
@testable import Dewline

/// Every library here works in a temporary folder and gets its downloads from the test, never the network.
@MainActor
struct FontLibraryTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DewlineFontTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The bundled JetBrains Mono Regular, served as if it were downloaded.
    private func bundledFont() throws -> Data {
        try Data(contentsOf: try #require(Bundle.main.resourceURL).appending(path: "Fonts/JetBrainsMono-Regular.ttf"))
    }

    private func entry(_ data: Data) -> FontCatalog.Family {
        FontCatalog.Family(
            name: "JetBrains Mono", role: .mono, folder: "jetbrainsmono", why: "", project: "https://github.com/JetBrains/JetBrainsMono",
            files: [FontCatalog.File(name: "JetBrainsMono-Regular.ttf", size: data.count, sha256: FontLibrary.sha256(data))]
        )
    }

    private func offline() -> FontLibrary.Fetch {
        { _, _, _ in
            Issue.record("A test reached for the network")
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Whether CoreText has a face of `family` loaded from `url`.
    private func registered(_ url: URL, _ family: String) -> Bool {
        Faces.faces(of: family).contains {
            (CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
        }
    }

    @Test func refusesATamperedDownload() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try bundledFont()
        var bytes = original
        bytes[bytes.count / 2] ^= 0xFF
        let tampered = bytes
        let library = FontLibrary(folder: folder) { _, _, _ in tampered }
        await #expect(throws: FontLibrary.Failure.mismatch) { try await library.install(entry(original)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(library.installed.isEmpty && library.progress.isEmpty)

        let file = entry(original).files[0]
        #expect(throws: FontLibrary.Failure.mismatch) { try FontLibrary.verify(original.dropLast(), against: file) }
        #expect(throws: FontLibrary.Failure.mismatch) { try FontLibrary.verify(original + [0], against: file) }
        try FontLibrary.verify(original, against: file)
    }

    @Test func installsAndRemovesInATemporaryFolder() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try bundledFont()
        let library = FontLibrary(folder: folder) { url, size, progress in
            #expect(url.scheme == "https" && size == data.count)
            await progress(size / 2)
            await progress(size)
            return data
        }
        try await library.install(entry(data))
        let font = folder.appending(path: "JetBrains Mono/JetBrainsMono-Regular.ttf")
        #expect(try Data(contentsOf: font) == data)
        #expect(library.installed == ["JetBrains Mono"] && library.progress.isEmpty)
        #expect(library.fonts(of: "JetBrains Mono").map(\.lastPathComponent) == ["JetBrainsMono-Regular.ttf"])
        #expect(registered(font, "JetBrains Mono"))

        let suite = "DewlineFontTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        store.headingFace = "JetBrains Mono"
        store.codeFace = "SF Mono"
        #expect(store.release("JetBrains Mono") == ["Headings"])
        #expect(store.headingFace == Faces.heading && store.codeFace == "SF Mono")

        try library.remove("JetBrains Mono")
        #expect(!FileManager.default.fileExists(atPath: font.deletingLastPathComponent().path))
        #expect(library.installed.isEmpty)
        #expect(!registered(font, "JetBrains Mono"))
        #expect(NSFont(name: "JetBrainsMono-Regular", size: 12) != nil, "the bundled copy stays")
    }

    @Test func dropInTakesFontsAndRefusesTheRest() throws {
        let folder = try temporaryFolder()
        let drops = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: drops)
        }
        let text = drops.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        let fake = drops.appending(path: "fake.ttf")
        try Data("not a font at all".utf8).write(to: fake)
        let header = drops.appending(path: "header.otf")
        try Data("OTTO and nothing else a font needs".utf8).write(to: header)
        let font = drops.appending(path: "JetBrainsMono-Regular.ttf")
        try bundledFont().write(to: font)

        #expect(throws: FontLibrary.Failure.notFontFile("notes.txt")) { try FontLibrary.validate(text) }
        #expect(throws: FontLibrary.Failure.notFont("fake.ttf")) { try FontLibrary.validate(fake) }
        #expect(throws: FontLibrary.Failure.notFont("header.otf")) { try FontLibrary.validate(header) }
        #expect(try FontLibrary.validate(font) == ["JetBrains Mono"])

        let library = FontLibrary(folder: folder, fetch: offline())
        let outcomes = library.add([text, fake, header, font, font])
        #expect(outcomes == [
            .refused("notes.txt isn't a .ttf, .otf or .ttc file."),
            .refused("fake.ttf isn't a font Dewline can read."),
            .refused("header.otf isn't a font Dewline can read."),
            .added("JetBrains Mono"),
            .alreadyAdded("JetBrains Mono"),
        ])
        let copy = folder.appending(path: "Added/JetBrainsMono-Regular.ttf")
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path) == ["JetBrainsMono-Regular.ttf"])
        #expect(library.addedFamilies == ["JetBrains Mono"] && library.added.first?.monospaced == true)
        #expect(registered(copy, "JetBrains Mono"))

        try library.remove("JetBrains Mono")
        #expect(library.added.isEmpty && !FileManager.default.fileExists(atPath: copy.path))
        #expect(!registered(copy, "JetBrains Mono"))
    }

    @Test func catalogPinsEveryFile() {
        #expect(FontCatalog.commit.wholeMatch(of: /[0-9a-f]{40}/) != nil)
        #expect(Set(FontCatalog.families.map(\.name)).count == FontCatalog.families.count)
        for family in FontCatalog.families {
            #expect(family.license == "SIL Open Font License 1.1")
            #expect(family.files.contains { $0.name == "OFL.txt" }, "\(family.name) ships without its license")
            #expect(family.files.contains { FontLibrary.isFontFile(URL(filePath: $0.name)) }, "\(family.name) has no font file")
            #expect(Set(family.files.map(\.name)).count == family.files.count)
            #expect(URL(string: family.project)?.scheme == "https")
            #expect(Bundle.main.url(forResource: family.name, withExtension: "pdf", subdirectory: "Specimens") != nil, "\(family.name) has no specimen")
            for file in family.files {
                #expect(file.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil, "\(family.name): \(file.name)")
                #expect(file.size > 0 && file.size < 50 << 20, "\(family.name): \(file.name)")
                let url = family.url(file)
                #expect(url.scheme == "https" && url.host() == "raw.githubusercontent.com")
                #expect(url.path(percentEncoded: false) == "/google/fonts/\(FontCatalog.commit)/ofl/\(family.folder)/\(file.name)")
            }
        }
        for pairing in Pairing.all {
            for face in pairing.faces {
                #expect(Faces.system.contains(face) || Faces.bundled.contains(face) || FontCatalog.family(face) != nil, "\(pairing.name): \(face)")
            }
        }
    }
}
