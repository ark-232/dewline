import AppKit
import PDFKit
import Testing
@testable import Dewline

@MainActor
struct ExportTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func exportWritesAPagedPDFWithoutShowingAWindow() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "# Report\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n<script>document.title = 'ran'</script>\n\n"
            + (1...120).map { "Paragraph \($0) of the long export." }.joined(separator: "\n\n")
        let url = folder.appending(path: "report.pdf")
        try await Export.write(text, title: "Report", as: .pdf, to: url, folder: folder)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("%PDF".utf8)))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Paragraph 120") == true)
        #expect(NSApp.windows.allSatisfy { !$0.isVisible })

        let html = folder.appending(path: "report.html")
        try await Export.write(text, title: "Report", as: .html, to: html, folder: folder)
        let page = try String(contentsOf: html, encoding: .utf8)
        #expect(page.contains("<table>") && page.contains("&lt;script&gt;") && !page.contains("<script>"))
    }

    @Test func pdfPrintsTheLightPaletteAndHTMLCarriesBoth() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func paper(_ name: NSAppearance.Name) -> NSColor {
            var color = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                color = ThemeStore.shared.color(.paper).usingColorSpace(.sRGB)!
            }
            return color
        }
        func hex(_ color: NSColor) -> String {
            String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        let (light, dark) = (paper(.aqua), paper(.darkAqua))
        #expect(hex(light) != hex(dark))
        let saved = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = saved }

        let url = folder.appending(path: "a.pdf")
        try await Export.write("# Title\n\nText.", title: "a", as: .pdf, to: url, folder: nil)
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let image = page.thumbnail(of: NSSize(width: 100, height: 130), for: .mediaBox)
        let tiff = try #require(image.tiffRepresentation)
        let corner = try #require(NSBitmapImageRep(data: tiff)?.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(abs(corner.redComponent - light.redComponent) + abs(corner.greenComponent - light.greenComponent) + abs(corner.blueComponent - light.blueComponent) < 0.06)

        let html = folder.appending(path: "a.html")
        try await Export.write("# Title", title: "a", as: .html, to: html, folder: nil)
        let css = try String(contentsOf: html, encoding: .utf8)
        let media = try #require(css.range(of: "@media (prefers-color-scheme: dark)"))
        #expect(css[..<media.lowerBound].contains("--paper: \(hex(light))"))
        #expect(css[media.upperBound...].contains("--paper: \(hex(dark))"))
    }
}
