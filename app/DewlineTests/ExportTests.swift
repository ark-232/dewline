import AppKit
import PDFKit
import Testing
@testable import Dewline

@MainActor
struct ExportTests {
    @Test func exportWritesAPagedPDFWithoutShowingAWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "# Report\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n<script>document.title = 'ran'</script>\n\n"
            + (1...120).map { "Paragraph \($0) of the long export." }.joined(separator: "\n\n")
        let url = folder.appending(path: "report.pdf")
        try await Export.write(text, title: "Report", as: .pdf, to: url, appearance: NSAppearance(named: .aqua)!)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("%PDF".utf8)))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Paragraph 120") == true)
        #expect(NSApp.windows.allSatisfy { !$0.isVisible })

        let html = folder.appending(path: "report.html")
        try await Export.write(text, title: "Report", as: .html, to: html, appearance: NSAppearance(named: .aqua)!)
        let page = try String(contentsOf: html, encoding: .utf8)
        #expect(page.contains("<table>") && page.contains("&lt;script&gt;") && !page.contains("<script>"))
    }
}
