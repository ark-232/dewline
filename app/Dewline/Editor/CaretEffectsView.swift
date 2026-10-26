import AppKit

/// The streak and the landing mark, above the text. Each is a committed Core Animation animation with no delegate,
/// so the app does no work while it runs or after it ends.
final class CaretEffectsView: NSView {
    // Hidden from the start: layout reads `marking` before the view has a backing layer.
    let streak: CAShapeLayer = {
        let streak = CAShapeLayer()
        streak.opacity = 0
        return streak
    }()
    let mark: CAShapeLayer = {
        let mark = CAShapeLayer()
        mark.opacity = 0
        mark.fillColor = nil
        mark.lineWidth = 1
        return mark
    }()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.addSublayer(mark)
        layer.addSublayer(streak)
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// A four-point shape whose leading corners start on the new caret rect and whose trailing corners spring from
    /// the old one onto it: critically damped, T = 0.12 s, fading from 0.45 over the first 55%.
    func streak(from old: NSRect, to new: NSRect, color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        streak.fillColor = color
        streak.path = Self.path(Self.corners(of: new))
        streak.opacity = 0
        streak.add(Self.streakAnimation(from: old, to: new), forKey: "streak")
        CATransaction.commit()
    }

    func removeStreak() {
        streak.removeAnimation(forKey: "streak")
    }

    /// A 1 pt outline around the target line: held 500 ms then faded over 300 ms, or static until the next input.
    func mark(_ line: NSRect, color: CGColor, fades: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.strokeColor = color
        mark.path = Self.outline(line)
        mark.opacity = fades ? 0 : 1
        mark.removeAnimation(forKey: "mark")
        if fades {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.625, 1]
            fade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
            fade.duration = 0.8
            mark.add(fade, forKey: "mark")
        }
        CATransaction.commit()
    }

    var marking: Bool {
        mark.opacity != 0 || mark.animation(forKey: "mark") != nil
    }

    func moveMark(to line: NSRect) {
        let outline = Self.outline(line)
        guard outline != mark.path else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.path = outline
        CATransaction.commit()
    }

    func clearMark() {
        guard mark.opacity != 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.opacity = 0
        CATransaction.commit()
    }

    static func streakAnimation(from old: NSRect, to new: NSRect) -> CAAnimation {
        let ends = corners(of: new)
        let ahead = { (corner: CGPoint) in (corner.x - new.midX) * (new.midX - old.midX) + (corner.y - new.midY) * (new.midY - old.midY) }
        let leading = Set(ends.indices.sorted { ahead(ends[$0]) > ahead(ends[$1]) }.prefix(2))
        let start = zip(corners(of: old), ends).enumerated().map { leading.contains($0.offset) ? $0.element.1 : $0.element.0 }
        let move = CASpringAnimation(keyPath: "path")
        move.fromValue = path(start)
        move.mass = 1
        move.stiffness = 1111
        move.damping = 66.7
        move.duration = 0.3
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.45, 0, 0]
        fade.keyTimes = [0, 0.55, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.3
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        return group
    }

    private static func outline(_ line: NSRect) -> CGPath {
        CGPath(roundedRect: line.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2, cornerHeight: 2, transform: nil)
    }

    private static func corners(of rect: NSRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }
}
