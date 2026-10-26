import AppKit
import Testing

struct BundledFontTests {
    @Test func jetBrainsMonoShipsWithTheApp() throws {
        let fonts = try #require(Bundle.main.resourceURL?.appendingPathComponent("Fonts"))
        for face in ["Regular", "Bold", "Italic", "BoldItalic"] {
            #expect(FileManager.default.fileExists(atPath: fonts.appendingPathComponent("JetBrainsMono-\(face).ttf").path))
        }
        #expect(NSFont(name: "JetBrainsMono-Regular", size: 15) != nil)
    }
}
