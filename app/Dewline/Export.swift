import AppKit
import MdCore
import UniformTypeIdentifiers
import WebKit

/// A document as a standalone HTML page or a paged PDF in the current theme: the PDF in its light palette, as paper
/// is, and the HTML in both, switched by the reader's appearance. The source file is never read or written: the page
/// comes from the text passed in, and images inline from the document's folder.
@MainActor
enum Export {
    enum Format: Int, CaseIterable {
        case html, pdf

        var type: UTType { self == .html ? .html : .pdf }
        var name: String { self == .html ? "HTML" : "PDF" }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// One appearance's colors: CSS custom properties, the diagram colors and the paper.
    @MainActor
    private struct Palette {
        let properties: String
        let colors: DiagramColors
        let paper: NSColor

        init(_ name: NSAppearance.Name) {
            var palette: (String, DiagramColors, NSColor)?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let tokens: [Token] = [.paper, .ink, .ink2, .heading, .link, .codeBackground, .quoteRule, .syntax]
                palette = (
                    tokens.map { "--\($0.rawValue): \(String(format: "#%08x", Export.rgba($0)));" }.joined(separator: " "),
                    DiagramColors(
                        paper: Export.rgba(.paper), ink: Export.rgba(.ink), ink2: Export.rgba(.ink2), accent: Export.rgba(.accent),
                        rule: Export.rgba(.syntax), fill: Export.rgba(.codeBackground)
                    ),
                    ThemeStore.shared.color(.paper).usingColorSpace(.sRGB)!
                )
            }
            (properties, colors, paper) = palette!
        }
    }

    static func write(_ text: String, title: String, as format: Format, to url: URL, folder: URL?) async throws {
        let light = Palette(.aqua)
        let dark = format == .html ? Palette(.darkAqua) : nil
        let page = exportPage(
            text, title: title, css: stylesheet(light: light, dark: dark), folder: folder, colors: light.colors, dark: dark?.colors,
            mathSize: ThemeStore.shared.bodySize
        )
        let data = switch format {
        case .html: Data(page.utf8)
        case .pdf: try await PDFRenderer().pdf(of: page, paper: light.paper)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Keeps the HTML page's stylesheet, in both palettes, in the app group's defaults for the Quick Look preview,
    /// whose sandbox can't read the app's settings.
    static func publishPreviewStylesheet() {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DewlineAppGroup") as? String else { return }
        UserDefaults(suiteName: group)?.set(stylesheet(light: Palette(.aqua), dark: Palette(.darkAqua)), forKey: "PreviewStylesheet")
    }

    private static func rgba(_ token: Token) -> UInt32 {
        let color = ThemeStore.shared.color(token).usingColorSpace(.sRGB)!
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
    }

    private static func family(_ face: String, _ generic: String) -> String {
        let system = ["New York": "ui-serif", "SF Pro": "system-ui", "SF Pro Rounded": "ui-rounded", "SF Mono": "ui-monospace"]
        let name = system[face] ?? "\"\(face.filter { !"\"\\;{}<>".contains($0) })\""
        return "\(name), \(generic)"
    }

    /// The editor's faces, and the theme's colors in the light palette, switched to `dark` on a dark page.
    private static func stylesheet(light: Palette, dark: Palette?) -> String {
        let store = ThemeStore.shared
        let scheme = dark.map { "@media (prefers-color-scheme: dark) { :root { \($0.properties) } }\n" } ?? ""
        return """
        :root { color-scheme: \(dark == nil ? "light" : "light dark"); \(light.properties) }
        \(scheme)html { background: var(--paper); }
        body { color: var(--ink); font-family: \(family(store.bodyFace, "serif")); font-size: \(store.bodySize)px; line-height: \(store.lineHeight); max-width: 40em; margin: 0 auto; padding: 2em 3em; }
        h1, h2, h3, h4, h5, h6 { font-family: \(family(store.headingFace, "serif")); color: var(--heading); line-height: 1.25; }
        a { color: var(--link); }
        code, pre { font-family: \(family(store.codeFace, "monospace")); font-size: 0.88em; background: var(--codeBackground); border-radius: 4px; }
        code { padding: 0.1em 0.3em; }
        pre { padding: 0.8em 1em; white-space: pre-wrap; }
        pre code { padding: 0; background: none; font-size: 1em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid var(--quoteRule); color: var(--ink2); }
        table { border-collapse: collapse; }
        th, td { border: 1px solid var(--syntax); padding: 0.3em 0.6em; }
        hr { border: 0; border-top: 1px solid var(--syntax); }
        img { max-width: 100%; }
        figure.diagram { margin: 1em 0; }
        figure.diagram svg { max-width: 100%; height: auto; }
        img.math { vertical-align: middle; }
        .math-display { display: block; text-align: center; margin: 1em 0; }
        .footnote-definition { font-size: 0.9em; color: var(--ink2); }
        """
    }

    /// The save panel for the window's document, set to `format`; a menu in the panel switches the format.
    static func run(for document: MarkdownDocument, text: String, format: Format, in window: NSWindow) {
        let panel = NSSavePanel()
        let title = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName ?? "Untitled"
        let formats = NSPopUpButton(frame: .zero, pullsDown: false)
        formats.addItems(withTitles: Format.allCases.map(\.name))
        formats.selectItem(at: format.rawValue)
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, formats])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = accessory
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = title
        func choose(_ format: Format) {
            panel.allowedContentTypes = [format.type]
        }
        choose(format)
        let chooser = PopUpTarget { choose(Format(rawValue: $0) ?? .html) }
        formats.target = chooser
        formats.action = #selector(PopUpTarget.changed(_:))
        let folder = document.fileURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(chooser) {}
            guard response == .OK, let url = panel.url, let format = Format(rawValue: formats.indexOfSelectedItem) else { return }
            Task { @MainActor in
                do {
                    try await write(text, title: title, as: format, to: url, folder: folder)
                } catch {
                    document.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                }
            }
        }
    }
}

@MainActor
private final class PopUpTarget: NSObject {
    let action: (Int) -> Void

    init(_ action: @escaping (Int) -> Void) {
        self.action = action
    }

    @objc func changed(_ sender: NSPopUpButton) {
        action(sender.indexOfSelectedItem)
    }
}

/// Lays out one page in a web view that runs no page script, keeps no data and follows no link, then cuts the PDF
/// of it into pages of the default paper size, breaking between top-level blocks where one fits.
@MainActor
private final class PDFRenderer: NSObject, WKNavigationDelegate {
    /// CSS pixels to points, as browsers print.
    private static let scale = 0.75
    private var loaded: CheckedContinuation<Void, any Error>?
    private var navigations = 0

    func pdf(of html: String, paper: NSColor) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let info = NSPrintInfo.shared
        let paperSize = info.paperSize
        let margin = 54.0
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: paperSize.width / Self.scale, height: 1000), configuration: configuration)
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            view.loadHTMLString(html, baseURL: nil)
        }
        let tops = (try? await view.callAsyncJavaScript(
            "return Array.from(document.body.children, e => e.getBoundingClientRect().top + window.scrollY)",
            contentWorld: .defaultClient
        ) as? [Double]) ?? []
        let tall = try await view.pdf()
        guard let document = CGDataProvider(data: tall as CFData).flatMap(CGPDFDocument.init), let page = document.page(at: 1) else {
            throw Export.Failure(errorDescription: "The page couldn’t be laid out as a PDF.")
        }
        let box = page.getBoxRect(.mediaBox)
        let capacity = (paperSize.height - 2 * margin) / Self.scale
        var starts = [0.0]
        while box.height - starts.last! > capacity {
            let start = starts.last!
            starts.append(tops.last { $0 > start + 1 && $0 <= start + capacity } ?? start + capacity)
        }
        let out = NSMutableData()
        var media = CGRect(origin: .zero, size: paperSize)
        guard let consumer = CGDataConsumer(data: out), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw Export.Failure(errorDescription: "The PDF couldn’t be written.")
        }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : box.height
            context.beginPDFPage(nil)
            context.setFillColor(paper.usingColorSpace(.sRGB)?.cgColor ?? .white)
            context.fill(media)
            let height = (end - start) * Self.scale
            context.clip(to: CGRect(x: 0, y: paperSize.height - margin - height, width: paperSize.width, height: height))
            context.translateBy(x: 0, y: paperSize.height - margin)
            context.scaleBy(x: Self.scale, y: Self.scale)
            context.translateBy(x: -box.minX, y: start - box.maxY)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
        return out as Data
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigations += 1
        return navigations == 1 ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}
