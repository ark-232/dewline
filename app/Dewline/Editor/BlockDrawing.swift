import AppKit

/// How one line of a rendered block lays out and draws: the value of `.dewlineBlock`. The picture's line reserves
/// its height, the block's other lines collapse, a failed block's last line carries the error below it, and folded
/// front matter's first line draws its summary. A laid-out table row draws its column rules, and a task item its box.
final class BlockLine: NSObject {
    enum Role {
        case picture(BlockPicture, label: String), collapsed, error(String), table(TableRule), task(TaskMark), summary(NSAttributedString)
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
        case let (.table(rule), .table(other)?): rule == other
        case let (.task(task), .task(other)?): task == other
        case let (.summary(line), .summary(other)?): line.isEqual(to: other)
        default: false
        }
    }

    override var hash: Int {
        switch role {
        case .picture(let picture, _): ObjectIdentifier(picture.image).hashValue
        case .collapsed: 0
        case .error(let message): message.hashValue
        case .table(let rule): rule.columns.count
        case .task(let task): task.at
        case .summary(let line): line.string.hashValue
        }
    }
}

/// A table line's rules, in points from where its text starts: one between each pair of columns, and for the
/// delimiter row one across them all.
struct TableRule: Equatable {
    let columns: [CGFloat]
    let width: CGFloat
    let across: Bool
    let color: NSColor
}

/// A task item's box over its hidden `[ ]`, which starts `at` characters into the line.
struct TaskMark: Equatable {
    let at: Int
    let checked: Bool
    let label: String
    let stroke: NSColor
    let fill: NSColor
    let check: NSColor
}

extension NSAttributedString.Key {
    static let dewlineBlock = NSAttributedString.Key("DewlineBlock")
}

/// Paragraphs that carry `.dewlineBlock` lay out as `BlockFragment`s.
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
        case .table(let rule):
            super.renderingSurfaceBounds.union(CGRect(x: 0, y: 0, width: textStart + rule.width + 1, height: layoutFragmentFrame.height))
        case .task: super.renderingSurfaceBounds
        case .summary(let line): CGRect(origin: .zero, size: CGSize(width: line.size().width + 16, height: layoutFragmentFrame.height))
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
            context.saveGState()
            context.translateBy(x: point.x, y: point.y + picture.size.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(picture.image, in: CGRect(origin: .zero, size: picture.size))
            context.restoreGState()
        case .collapsed:
            break
        case .summary(let line):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            line.draw(at: CGPoint(x: point.x + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0), y: point.y + (layoutFragmentFrame.height - line.size().height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        case .error(let message):
            super.draw(at: point, in: context)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: CGPoint(x: point.x, y: point.y + textBottom + 3))
            NSGraphicsContext.restoreGraphicsState()
        case .table(let rule):
            super.draw(at: point, in: context)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            rule.color.setFill()
            let left = point.x + textStart
            for x in rule.columns {
                NSRect(x: left + x - 0.5, y: point.y, width: 1, height: layoutFragmentFrame.height).fill()
            }
            if rule.across {
                NSRect(x: left, y: point.y + (layoutFragmentFrame.height / 2).rounded() - 0.5, width: rule.width, height: 1).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        case .task(let task):
            super.draw(at: point, in: context)
            guard let box = taskBoxRect?.offsetBy(dx: point.x, dy: point.y) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: box.width * 0.22, yRadius: box.width * 0.22)
            outline.lineWidth = 1.5
            if task.checked {
                task.fill.setFill()
                outline.fill()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.52))
                mark.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.7))
                mark.line(to: NSPoint(x: box.minX + box.width * 0.76, y: box.minY + box.height * 0.3))
                mark.lineWidth = 1.75
                mark.lineCapStyle = .round
                mark.lineJoinStyle = .round
                task.check.setStroke()
                mark.stroke()
            } else {
                task.stroke.setStroke()
                outline.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Where the first line's text starts, in this fragment's coordinates.
    private var textStart: CGFloat {
        guard let line = textLineFragments.first else { return 0 }
        return line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.location).x
    }

    /// A task's box, in this fragment's coordinates: a square over the `[ ]` that sits on the baseline.
    var taskBoxRect: CGRect? {
        guard case .task(let task) = line.role,
            let text = textLineFragments.first(where: { NSLocationInRange(task.at, $0.characterRange) })
        else { return nil }
        let start = text.locationForCharacter(at: task.at).x
        let end = text.locationForCharacter(at: task.at + 3).x
        let bounds = text.typographicBounds
        let side = min(end - start, bounds.height * 0.6).rounded()
        let baseline = bounds.minY + text.glyphOrigin.y
        return CGRect(x: bounds.minX + start + ((end - start - side) / 2).rounded(), y: (baseline + 1 - side).rounded(), width: side, height: side)
    }
}
