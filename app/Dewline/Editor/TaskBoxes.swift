import AppKit

/// GFM task boxes drawn as checkboxes while the selection is outside their `[ ]`, which stays in the storage, clear.
/// A click on a box toggles the literal character between space and `x`.
@MainActor
final class TaskBoxes {
    private let map: BlockMap
    /// The boxes showing their source.
    private var revealed: Set<NSRange> = []

    init(map: BlockMap) {
        self.map = map
    }

    /// Moves the revealed boxes past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { range in
            if NSMaxRange(range) < edited.location { return range }
            return range.location > oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        })
    }

    /// The boxes the selection entered or left since they were last styled.
    func revealChanges(_ selection: [NSRange]) -> [NSRange] {
        var now: Set<NSRange> = []
        for range in selection {
            for block in map.blocks(touching: range) {
                for box in Self.boxes(block) where Self.touches(box.range, selection) { now.insert(box.range) }
            }
        }
        return Array(now.symmetricDifference(revealed))
    }

    /// Styles the boxes in `styled`, a copy of the storage from `offset` on, for a selection in its coordinates.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange]) {
        let whole = NSRange(location: offset, length: styled.length)
        revealed = revealed.filter { !NSLocationInRange($0.location, whole) }
        let store = ThemeStore.shared
        let text = styled.mutableString
        for block in map.blocks(in: whole) {
            for box in Self.boxes(block) {
                let local = box.shifted(by: -offset)
                guard local.range.location >= 0, NSMaxRange(local.range) <= styled.length, case .taskBox(let checked) = box.kind else { continue }
                if Self.touches(local.range, selection) {
                    revealed.insert(box.range)
                    for marker in local.markers { styled.addAttribute(.foregroundColor, value: store.color(.syntax), range: marker) }
                    continue
                }
                styled.addAttribute(.foregroundColor, value: NSColor.clear, range: local.range)
                let paragraph = text.paragraphRange(for: local.range)
                var end = NSMaxRange(paragraph)
                while end > NSMaxRange(local.range), [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
                let label = text.substring(with: NSRange(location: NSMaxRange(local.range), length: end - NSMaxRange(local.range)))
                let mark = TaskMark(
                    at: local.range.location - paragraph.location, checked: checked, label: label.trimmingCharacters(in: .whitespaces),
                    stroke: store.color(.ink2), fill: store.color(.accent), check: store.color(.paper)
                )
                styled.addAttribute(.dewlineBlock, value: BlockLine(.task(mark)), range: paragraph)
            }
        }
    }

    /// A block's task boxes, in the document.
    private static func boxes(_ block: BlockMap.Block) -> [SyntaxSpan] {
        block.spans.filter { if case .taskBox = $0.kind { true } else { false } }.map { $0.shifted(by: block.range.location) }
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }
}

/// A task box as VoiceOver finds it: a checkbox named by its item's text, which a press toggles.
final class TaskBoxElement: NSAccessibilityElement {
    private let toggle: () -> Void

    init(frame: NSRect, label: String, checked: Bool, parent: Any, toggle: @escaping () -> Void) {
        self.toggle = toggle
        super.init()
        setAccessibilityRole(.checkBox)
        setAccessibilityFrame(frame)
        setAccessibilityLabel(label)
        setAccessibilityValue(checked ? 1 : 0)
        setAccessibilityParent(parent)
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
}

extension EditorTextView {
    /// The checked character of the box drawn at `point`, in this view's coordinates.
    func taskBox(at point: NSPoint) -> Int? {
        guard !styler.showsSource, let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard let fragment = layout.textLayoutFragment(for: inContainer) as? BlockFragment, case .task(let task) = fragment.line.role,
            let box = fragment.taskBoxRect?.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY),
            box.insetBy(dx: -3, dy: -3).contains(inContainer)
        else { return nil }
        return content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location) + task.at + 1
    }

    /// Toggles the box whose checked character is at `index` between space and `x`, as one undoable edit.
    func toggleTask(at index: Int) {
        let storage = textStorage!
        let range = NSRange(location: index, length: 1)
        let mark = storage.mutableString.substring(with: range) == " " ? "x" : " "
        history.perform(mark == "x" ? "Check Task" : "Uncheck Task") {
            guard shouldChangeText(in: range, replacementString: mark) else { return }
            // The caret stays where it is.
            styler.landing = nil
            storage.replaceCharacters(in: range, with: mark)
            didChangeText()
        }
    }
}
