import AppKit
import MdCore

/// `$...$` math drawn at the text's size on its baseline while the selection is outside it. The source stays in the
/// storage, hidden; a kern on its first character holds the formula's width, and the view draws the formula there.
/// Until the formula is drawn, and when its TeX fails, the source shows.
@MainActor
final class InlineMath {
    weak var textView: EditorTextView?
    private let map: BlockMap
    /// The spans showing their source.
    private var revealed: Set<NSRange> = []
    private var formulas: [Request: Result<InlineFormula, RenderFailure>] = [:]
    private var pending: Set<Request> = []
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.inline-math", qos: .userInitiated)

    /// What a formula's picture depends on.
    struct Request: Hashable, Sendable {
        let tex: String
        let size: CGFloat
        let scale: CGFloat
        /// sRGB 0xRRGGBBAA.
        let color: UInt32
    }

    init(map: BlockMap) {
        self.map = map
    }

    /// Moves the revealed spans past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { range in
            if NSMaxRange(range) < edited.location { return range }
            return range.location > oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        })
    }

    /// The spans the selection entered or left since they were last styled.
    func revealChanges(_ selection: [NSRange]) -> [NSRange] {
        var now: Set<NSRange> = []
        for range in selection {
            for block in map.blocks(touching: range) {
                for span in Self.spans(block) where Self.touches(span.range, selection) { now.insert(span.range) }
            }
        }
        return Array(now.symmetricDifference(revealed))
    }

    /// Styles the inline math in `styled`, a copy of the storage from `offset` on, for a selection in its coordinates.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange]) {
        let whole = NSRange(location: offset, length: styled.length)
        revealed = revealed.filter { !NSLocationInRange($0.location, whole) }
        guard let textView else { return }
        for block in map.blocks(in: whole) {
            for span in Self.spans(block) {
                let local = span.shifted(by: -offset)
                guard local.range.location >= 0, NSMaxRange(local.range) <= styled.length, local.content.length > 0 else { continue }
                if Self.touches(local.range, selection) {
                    revealed.insert(span.range)
                    continue
                }
                let font = styled.attribute(.font, at: local.content.location, effectiveRange: nil) as? NSFont ?? MarkdownStyler.bodyFont
                let color = styled.attribute(.foregroundColor, at: local.content.location, effectiveRange: nil) as? NSColor
                let request = Request(
                    tex: styled.mutableString.substring(with: local.content), size: font.pointSize,
                    scale: textView.window?.backingScaleFactor ?? 2, color: Self.rgba(color ?? ThemeStore.shared.color(.ink), in: textView)
                )
                switch formulas[request] {
                case .success(let formula)?:
                    styled.addAttributes([.font: MarkdownStyler.hiddenFont, .foregroundColor: NSColor.clear, .dewlineMath: formula], range: local.range)
                    styled.addAttribute(.kern, value: formula.size.width, range: NSRange(location: local.range.location, length: 1))
                case .failure?:
                    continue
                case nil:
                    render(request)
                }
            }
        }
    }

    /// Draws `request` off the main thread, then restyles the spans that show it.
    private func render(_ request: Request) {
        guard pending.insert(request).inserted else { return }
        queue.async { [weak self] in
            let result = Result { () throws(RenderFailure) in
                try ratexInlineImage(request.tex, size: Double(request.size), scale: Double(request.scale), color: request.color)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView, let storage = textView.textStorage else { return }
                    self.pending.remove(request)
                    if self.formulas.count > 512 { self.formulas = [:] }
                    self.formulas[request] = result.map { InlineFormula(image: $0.image, scale: request.scale, depth: $0.depth) }
                    let text = storage.mutableString
                    for block in self.map.blocks(in: NSRange(location: 0, length: storage.length)) {
                        for span in Self.spans(block) where NSMaxRange(span.content) <= text.length && text.substring(with: span.content) == request.tex {
                            textView.styler.restyleNow(span.range)
                        }
                    }
                    textView.needsDisplay = true
                }
            }
        }
    }

    /// A block's inline math, in the document; a table's cells keep their source.
    private static func spans(_ block: BlockMap.Block) -> [SyntaxSpan] {
        guard block.kind != .tableHead, block.kind != .tableRow else { return [] }
        return block.spans.filter { $0.kind == .inlineMath }.map { $0.shifted(by: block.range.location) }
    }

    private static func rgba(_ color: NSColor, in view: NSView) -> UInt32 {
        var value: UInt32 = 0
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = color.usingColorSpace(.sRGB) ?? .black
            value = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                .reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
        }
        return value
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }
}

/// A drawn formula: its picture, its size in points, and how far it reaches below the baseline.
final class InlineFormula: NSObject {
    let image: NSImage
    let size: CGSize
    let depth: CGFloat

    init(image: CGImage, scale: CGFloat, depth: Double) {
        size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        self.image = NSImage(cgImage: image, size: size)
        self.depth = CGFloat(depth)
    }
}

extension EditorTextView {
    /// Draws each inline formula in `visible` over its hidden source, sitting on the line's baseline.
    func drawInlineMath(in visible: NSRange, line: (Int) -> NSRect) {
        let storage = textStorage!
        var drawn = Set<Int>()
        storage.enumerateAttribute(.dewlineMath, in: visible) { value, range, _ in
            guard let formula = value as? InlineFormula else { return }
            var whole = NSRange()
            storage.attribute(.dewlineMath, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            guard drawn.insert(whole.location).inserted, let baseline = baseline(at: whole.location) else { return }
            let rect = NSRect(
                x: line(whole.location).minX, y: baseline + formula.depth - formula.size.height, width: formula.size.width, height: formula.size.height
            )
            formula.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

extension NSAttributedString.Key {
    /// Inline math drawn as an `InlineFormula` over its hidden source.
    static let dewlineMath = NSAttributedString.Key("DewlineMath")
}
