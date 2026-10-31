import MdCore
import QuickLookUI
import UniformTypeIdentifiers

/// Finder's preview of a Markdown file: the page export writes, as data, in the app's stylesheet, with diagrams and
/// math as their source. The page runs no script and loads nothing from the network.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        // The app keeps its stylesheet in the group's defaults; this sandbox can't read the app's own.
        let group = Bundle.main.object(forInfoDictionaryKey: "DewlineAppGroup") as? String
        let css = group.flatMap { UserDefaults(suiteName: $0)?.string(forKey: "PreviewStylesheet") } ?? ""
        let page = previewPage(text, title: url.deletingPathExtension().lastPathComponent, css: css)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 1000)) { _ in Data(page.utf8) }
    }
}
