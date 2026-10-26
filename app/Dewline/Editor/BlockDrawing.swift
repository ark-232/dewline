import AppKit

/// How one line of a rendered block lays out and draws: the value of `.dewlineBlock`. The picture's line reserves
/// its height, the block's other lines collapse, and a failed block's last line carries the error below it.
final class BlockLine: NSObject {
    enum Role {
        case picture(BlockPicture, label: String), collapsed, error(String)
    }

    let role: Role
    static let errorHeight: CGFloat = 20

    init(_ role: Role) {
        self.role = role
    }

    override func isEqual(_ object: Any?) -> Bool {
        switch (role, (object as? BlockLine)?.role) {
        case let (.picture(picture, label), .picture(other, otherLabel)?):
            picture.image === other.image && picture.size == other.size && label == otherLabel
        case (.collapsed, .collapsed?): true
        case let (.error(message), .error(other)?): message == other
        default: false
        }
    }

    override var hash: Int {
        switch role {
        case .picture(let picture, _): ObjectIdentifier(picture.image).hashValue
        case .collapsed: 0
        case .error(let message): message.hashValue
        }
    }

    static func draw(_ picture: BlockPicture, at origin: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + picture.size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(picture.image, in: CGRect(origin: .zero, size: picture.size))
        context.restoreGState()
    }

    static func draw(error message: String, at origin: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: CGPoint(x: origin.x, y: origin.y + 3))
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSAttributedString.Key {
    static let dewlineBlock = NSAttributedString.Key("DewlineBlock")
}

/// TextKit 2: paragraphs that carry `.dewlineBlock` lay out as `BlockFragment`s.
final class BlockFragments: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
            let line = paragraph.attributedString.attribute(.dewlineBlock, at: 0, effectiveRange: nil) as? BlockLine
        else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }
        return BlockFragment(line, textElement: textElement)
    }
}

/// Draws a block's picture in place of its hidden first line, nothing for its collapsed lines, and the error
/// under a failed block's source. The heights come from the line's paragraph style.
final class BlockFragment: NSTextLayoutFragment {
    let line: BlockLine

    init(_ line: BlockLine, textElement: NSTextElement) {
        self.line = line
        super.init(textElement: textElement, range: textElement.elementRange)
    }

    required init?(coder: NSCoder) {
        fatalError("BlockFragment is built in code")
    }

    private var textBottom: CGFloat {
        textLineFragments.last?.typographicBounds.maxY ?? 0
    }

    override var renderingSurfaceBounds: CGRect {
        switch line.role {
        case .picture(let picture, _): CGRect(origin: .zero, size: picture.size)
        case .collapsed: .zero
        case .error:
            // The error is wider than the line it hangs under.
            super.renderingSurfaceBounds.union(CGRect(
                x: 0, y: textBottom, width: textLayoutManager?.textContainer?.size.width ?? 0, height: BlockLine.errorHeight
            ))
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        switch line.role {
        case .picture(let picture, _):
            BlockLine.draw(picture, at: point, in: context)
        case .collapsed:
            break
        case .error(let message):
            super.draw(at: point, in: context)
            BlockLine.draw(error: message, at: CGPoint(x: point.x, y: point.y + textBottom), in: context)
        }
    }
}

/// TextKit 1: draws block pictures and error lines behind the glyphs. `HiddenGlyphs` sets the line heights.
final class BlockLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let context = NSGraphicsContext.current?.cgContext else { return }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, used, container, glyphs, _ in
            let characters = self.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard characters.location < storage.length else { return }
            var run = NSRange()
            guard let line = storage.attribute(.dewlineBlock, at: characters.location, effectiveRange: &run) as? BlockLine else { return }
            let left = origin.x + rect.minX + container.lineFragmentPadding
            switch line.role {
            case .picture(let picture, _):
                BlockLine.draw(picture, at: CGPoint(x: left, y: origin.y + rect.minY), in: context)
            case .error(let message) where NSMaxRange(characters) >= NSMaxRange(run):
                BlockLine.draw(error: message, at: CGPoint(x: left, y: origin.y + used.maxY), in: context)
            default:
                break
            }
        }
    }
}
