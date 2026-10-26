import AppKit
import MdCore

/// Fenced Mermaid, `$$` math and lone images, drawn as pictures while the selection is outside them. The source
/// stays in the storage: a collapsed block hides it, its first line reserves the picture's height, and
/// `.dewlineBlock` tells the layout what to draw. A revealed, pending or failed block shows its source monospaced,
/// and a failed one adds a dim line naming the error.
@MainActor
final class RenderedBlocks {
    weak var textView: EditorTextView?
    private(set) var index = BlockIndex()
    private var revealed: Set<RenderedBlock> = []
    private var pictures: [PictureRequest: Result<BlockPicture, RenderFailure>] = [:]
    private var pending: Set<PictureRequest> = []
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.pictures", qos: .utility)

    private static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let sourceLines = lines(20)
    private static let collapsedLines = lines(0.01)

    /// Ranges to restyle beyond the edited paragraphs: blocks the edit made, changed or broke.
    func textDidChange(_ text: NSString, edited: NSRange, delta: Int) -> [NSRange] {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { block in
            if NSMaxRange(block.range) < edited.location { return block }
            return block.range.location > oldEnd ? block.shifted(by: delta) : nil
        })
        let changed = index.update(text, edited: edited, delta: delta)
        revealed.formIntersection(index.blocks)
        return changed
    }

    /// Whether `range` lies in a block, where markdown spans do not apply.
    func contains(_ range: NSRange) -> Bool {
        index.blocks.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    /// Ranges of the blocks the selection entered or left since they were last styled.
    func revealChanges(_ selection: [NSRange]) -> [NSRange] {
        Set(index.blocks.filter { Self.touches($0.range, selection) }).symmetricDifference(revealed).map(\.range)
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
        for block in index.blocks where NSIntersectionRange(block.range, paragraphs).length > 0 {
            let range = NSRange(location: block.range.location - offset, length: block.range.length)
            let overlap = NSIntersectionRange(block.range, paragraphs)
            let local = NSRange(location: overlap.location - offset, length: overlap.length)
            let reveal = Self.touches(range, selection)
            if reveal { revealed.insert(block) } else { revealed.remove(block) }
            let request = request(for: block, in: textView)
            let picture = pictures[request]
            if picture == nil, !reveal, width > 0, pending.insert(request).inserted {
                queue.async { [weak self] in
                    let picture = request.render(width: width)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, let textView = self.textView else { return }
                            self.pending.remove(request)
                            let shown = self.index.blocks.map { ($0, self.request(for: $0, in: textView)) }
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
                    if textView.textLayoutManager == nil {
                        styled.addAttribute(.dewlineHidden, value: true, range: line)
                    } else {
                        styled.addAttribute(.font, value: MarkdownStyler.hiddenFont, range: line)
                        styled.addAttribute(.paragraphStyle, value: first ? Self.lines(fitted.height) : Self.collapsedLines, range: paragraph)
                    }
                }
                continue
            }
            styled.addAttributes([.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.sourceLines], range: local)
            for marker in [NSRange(location: block.range.location, length: block.content.location - block.range.location),
                           NSRange(location: NSMaxRange(block.content), length: NSMaxRange(block.range) - NSMaxRange(block.content))] {
                let part = NSIntersectionRange(marker, paragraphs)
                guard part.length > 0 else { continue }
                styled.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: part.location - offset, length: part.length))
            }
            if case .failure(let failure) = picture, NSMaxRange(range) <= styled.length {
                let last = NSIntersectionRange(text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)), whole)
                let spaced = Self.sourceLines.mutableCopy() as! NSMutableParagraphStyle
                spaced.paragraphSpacing = BlockLine.errorHeight
                let name = switch block.kind {
                case .mermaid: "Mermaid"
                case .math: "TeX"
                case .image: "Image"
                }
                let reason = failure.reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? failure.reason
                styled.addAttributes([.paragraphStyle: spaced, .dewlineBlock: BlockLine(.error("\(name): \(reason)"))], range: last)
            }
        }
    }

    private func request(for block: RenderedBlock, in textView: EditorTextView) -> PictureRequest {
        var source = block.source
        var ink: UInt32 = 0
        switch block.kind {
        case .mermaid:
            break
        case .math:
            // The label color as sRGB 0xRRGGBBAA in the view's appearance.
            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let color = NSColor.labelColor.usingColorSpace(.sRGB) else { return }
                ink = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                    .reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
            }
        case .image:
            source = textView.documentFolder.map { $0.appending(path: block.source).standardizedFileURL.path } ?? ""
        }
        return PictureRequest(
            kind: block.kind, source: source, scale: textView.window?.backingScaleFactor ?? 2, color: ink, engine: MathEngine.current
        )
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
