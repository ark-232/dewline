import AppKit
import MdCore

/// Fenced Mermaid, `$$` math and lone images, drawn as pictures while the selection is outside them. The source
/// stays in the storage: a collapsed block hides it, its first line reserves the picture's height, and
/// `.dewlineBlock` tells the layout what to draw. A revealed, pending or failed block shows its source monospaced,
/// and a failed one adds a dim line naming the error.
@MainActor
final class RenderedBlocks {
    weak var textView: EditorTextView?
    private let map: BlockMap
    private var revealed: Set<RenderedBlock> = []
    private var pictures: [PictureRequest: Result<BlockPicture, RenderFailure>] = [:]
    private var pending: Set<PictureRequest> = []
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.pictures", qos: .utility)

    private static let sourceLines = lines(20)
    private static let collapsedLines = lines(0.01)

    init(map: BlockMap) {
        self.map = map
    }

    /// Moves the revealed blocks past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { block in
            if NSMaxRange(block.range) < edited.location { return block }
            return block.range.location > oldEnd ? block.shifted(by: delta) : nil
        })
        textDidParse()
    }

    /// Forgets the revealed blocks the map no longer has.
    func textDidParse() {
        revealed = revealed.filter { map.renderedBlocks(in: $0.range).contains($0) }
    }

    /// Ranges of the blocks the selection entered or left since they were last styled.
    func revealChanges(_ selection: [NSRange]) -> [NSRange] {
        let touched = selection.flatMap(map.renderedBlocks(touching:)).filter { Self.touches($0.range, selection) }
        return Set(touched).symmetricDifference(revealed).map(\.range)
    }

    /// Styles the blocks that meet `styled`, a copy of the storage from `offset` on, for a selection in its
    /// coordinates.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange]) {
        let whole = NSRange(location: 0, length: styled.length)
        styled.removeAttribute(.dewlineBlock, range: whole)
        guard let textView else { return }
        let text = styled.mutableString
        let paragraphs = NSRange(location: offset, length: styled.length)
        let width = (textView.textContainer?.size.width ?? 0) - 2 * (textView.textContainer?.lineFragmentPadding ?? 0)
        for block in map.renderedBlocks(in: paragraphs) {
            let range = NSRange(location: block.range.location - offset, length: block.range.length)
            let overlap = NSIntersectionRange(block.range, paragraphs)
            let local = NSRange(location: overlap.location - offset, length: overlap.length)
            let reveal = Self.touches(range, selection)
            if reveal { revealed.insert(block) } else { revealed.remove(block) }
            if block.kind == .frontMatter, !reveal {
                fold(block, at: range, local: local, in: styled)
                continue
            }
            let request = block.kind == .frontMatter ? nil : request(for: block, in: textView)
            let picture = request.flatMap { pictures[$0] }
            if let request, picture == nil, !reveal, width > 0, pending.insert(request).inserted {
                queue.async { [weak self] in
                    let picture = request.render(width: width)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, let textView = self.textView else { return }
                            self.pending.remove(request)
                            let all = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
                            let shown = self.map.renderedBlocks(in: all).map { ($0, self.request(for: $0, in: textView)) }
                            self.pictures = self.pictures.filter { key, _ in shown.contains { $0.1 == key } }
                            self.pictures[request] = picture
                            for (block, key) in shown where key == request { textView.styler.restyleNow(block.range) }
                        }
                    }
                }
            }
            if !reveal, case .success(let picture) = picture {
                let fitted = picture.size.width > width ? CGSize(width: width, height: picture.size.height * width / picture.size.width) : picture.size
                text.enumerateSubstrings(in: local, options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
                    let first = line.location == range.location
                    let role: BlockLine.Role = first ? .picture(BlockPicture(image: picture.image, size: fitted), label: block.label) : .collapsed
                    let paragraph = NSIntersectionRange(enclosing, whole)
                    styled.addAttribute(.dewlineBlock, value: BlockLine(role), range: paragraph)
                    styled.addAttribute(.foregroundColor, value: NSColor.clear, range: line)
                    styled.addAttribute(.font, value: MarkdownStyler.hiddenFont, range: line)
                    styled.addAttribute(.paragraphStyle, value: first ? Self.lines(fitted.height) : Self.collapsedLines, range: paragraph)
                }
                continue
            }
            let source: [NSAttributedString.Key: Any] = [
                .font: MarkdownStyler.code(matching: MarkdownStyler.bodyFont), .foregroundColor: ThemeStore.shared.color(.ink), .paragraphStyle: Self.sourceLines,
            ]
            styled.addAttributes(source, range: local)
            for marker in [NSRange(location: block.range.location, length: block.content.location - block.range.location),
                           NSRange(location: NSMaxRange(block.content), length: NSMaxRange(block.range) - NSMaxRange(block.content))] {
                let part = NSIntersectionRange(marker, paragraphs)
                guard part.length > 0 else { continue }
                styled.addAttribute(.foregroundColor, value: ThemeStore.shared.color(.syntax), range: NSRange(location: part.location - offset, length: part.length))
            }
            if case .failure(let failure) = picture, NSMaxRange(range) <= styled.length {
                let last = NSIntersectionRange(text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)), whole)
                let spaced = Self.sourceLines.mutableCopy() as! NSMutableParagraphStyle
                spaced.paragraphSpacing = BlockLine.errorHeight
                let name = switch block.kind {
                case .mermaid: "Mermaid"
                case .math: "TeX"
                case .image: "Image"
                case .frontMatter: "Front matter"
                }
                let reason = failure.reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? failure.reason
                styled.addAttributes([.paragraphStyle: spaced, .dewlineBlock: BlockLine(.error("\(name): \(reason)"))], range: last)
            }
        }
    }

    private func request(for block: RenderedBlock, in textView: EditorTextView) -> PictureRequest {
        var source = block.source
        var colors: DiagramColors?
        switch block.kind {
        case .mermaid, .math:
            func rgba(_ token: Token) -> UInt32 {
                let color = ThemeStore.shared.color(token).usingColorSpace(.sRGB)!
                return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                    .reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
            }
            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                colors = DiagramColors(
                    paper: rgba(.paper), ink: rgba(.ink), ink2: rgba(.ink2), accent: rgba(.accent), rule: rgba(.syntax), fill: rgba(.codeBackground)
                )
            }
        case .image, .frontMatter:
            source = textView.documentFolder.map { $0.appending(path: block.source).standardizedFileURL.path } ?? ""
        }
        return PictureRequest(kind: block.kind, source: source, scale: textView.window?.backingScaleFactor ?? 2, colors: colors)
    }

    /// Folds front matter to one dim line naming its field count; its other lines collapse.
    private func fold(_ block: RenderedBlock, at range: NSRange, local: NSRange, in styled: NSMutableAttributedString) {
        let store = ThemeStore.shared
        let font = NSFont.systemFont(ofSize: (store.bodyFont.pointSize * 0.8).rounded())
        let summary = NSAttributedString(string: block.label, attributes: [.font: font, .foregroundColor: store.color(.ink2)])
        let whole = NSRange(location: 0, length: styled.length)
        styled.mutableString.enumerateSubstrings(in: local, options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            let first = line.location == range.location
            let paragraph = NSIntersectionRange(enclosing, whole)
            styled.addAttribute(.dewlineBlock, value: BlockLine(first ? .summary(summary) : .collapsed), range: paragraph)
            styled.addAttributes([.foregroundColor: NSColor.clear, .font: MarkdownStyler.hiddenFont], range: line)
            styled.addAttribute(.paragraphStyle, value: first ? store.paragraphStyle(lineHeight: store.bodyLineHeight) : Self.collapsedLines, range: paragraph)
        }
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }

    private static func lines(_ height: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return style
    }
}
