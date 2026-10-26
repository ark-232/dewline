import AppKit
import Testing
@testable import Dewline

/// A window that reports itself key without being ordered front, so a text view in it builds and drives the system
/// insertion indicator.
final class KeyWindow: NSWindow {
    var key = true

    override var isKeyWindow: Bool { key }
}

/// A stock text view with its caret placed in a key window on the given screen.
@MainActor
private struct Stock {
    let window: KeyWindow
    let view: NSTextView

    init(_ variant: TextKitVariant, size: CGFloat = 17, screen: NSScreen? = nil) {
        view = NSTextView(usingTextLayoutManager: variant == .textKit2)
        view.font = .systemFont(ofSize: size)
        view.string = "Hello world\nSecond line\n"
        window = KeyWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        let deadline = Date(timeIntervalSinceNow: 2)
        while bar == nil && Date() < deadline { settle() }
    }

    func settle() {
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    var indicator: NSTextInsertionIndicator? {
        view.subviews.lazy.compactMap { $0 as? NSTextInsertionIndicator }.first
    }

    /// The bar the indicator draws: the sublayer of its layer that has a background color.
    var bar: CALayer? {
        indicator?.layer?.sublayers?.first { $0.backgroundColor != nil }
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

private func srgb(_ color: CGColor?) throws -> [Double] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(color?.converted(to: space, intent: .defaultIntent, options: nil)?.components).map(Double.init)
}

/// The vertices of a closed four-point path, read from its element end points.
private func corners(_ path: CGPath?) -> [CGPoint] {
    var points: [CGPoint] = []
    path?.applyWithBlock { element in
        switch element.pointee.type {
        case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
        case .addQuadCurveToPoint: points.append(element.pointee.points[1])
        case .addCurveToPoint: points.append(element.pointee.points[2])
        case .closeSubpath: break
        @unknown default: break
        }
    }
    return Array(points.prefix(4))
}

/// Section 5.6 of the motion spec on this Mac, for both TextKit stacks.
@MainActor
struct CaretSpikeTests {
    /// S1 and S3: the drawn bar takes `insertionPointColor`, resolved per appearance; `.clear` leaves it with no
    /// color while the indicator stays in place with its effects view option.
    @Test(arguments: TextKitVariant.allCases)
    func s1BarFollowsInsertionPointColor(_ variant: TextKitVariant) throws {
        let stock = Stock(variant)
        defer { stock.close() }
        stock.view.insertionPointColor = CaretTextView.accent
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            stock.window.appearance = NSAppearance(named: appearance)
            stock.settle()
            var accent: CGColor?
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { accent = CaretTextView.accent.cgColor }
            let expected = try srgb(accent)
            let rgb = try srgb(try #require(stock.bar).backgroundColor)
            #expect(zip(rgb, expected).allSatisfy { abs($0 - $1) < 0.002 }, "\(appearance.rawValue): \(rgb)")
        }
        stock.view.insertionPointColor = .clear
        stock.settle()
        #expect(try srgb(try #require(stock.bar).backgroundColor).last == 0)
        let indicator = try #require(stock.indicator)
        #expect(indicator.automaticModeOptions.contains(.showEffectsView))
        #expect(indicator.displayMode != .hidden)
    }

    /// S2: the indicator is a direct subview once the view is first responder in a key window; `.visible` holds
    /// with no input; a selection change puts it back to automatic on both stacks, and a layout pass does on TextKit 2.
    @Test(arguments: TextKitVariant.allCases)
    func s2IndicatorIsReachableAndHoldsVisible(_ variant: TextKitVariant) throws {
        let stock = Stock(variant)
        defer { stock.close() }
        let indicator = try #require(stock.indicator)
        #expect(indicator.superview === stock.view)
        indicator.displayMode = .visible
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        stock.settle()
        #expect(indicator.displayMode == .visible)
        #expect(stock.bar?.opacity == 1)
        stock.view.setSelectedRange(NSRange(location: 7, length: 0))
        #expect(indicator.displayMode == .automatic)
        indicator.displayMode = .visible
        stock.view.needsLayout = true
        stock.view.layoutSubtreeIfNeeded()
        #expect((indicator.displayMode == .visible) == (variant == .textKit1))
    }

    /// S4: the bar is 2 pt wide and centered on the insertion point at every size, on every screen this Mac has.
    @Test(arguments: TextKitVariant.allCases)
    func s4BarIsTwoPointsWide(_ variant: TextKitVariant) throws {
        let screens: [NSScreen?] = NSScreen.screens.isEmpty ? [nil] : NSScreen.screens
        for screen in screens {
            for size in [13.0, 17.0, 24.0] {
                let stock = Stock(variant, size: size, screen: screen)
                defer { stock.close() }
                let bar = try #require(stock.bar)
                let label = "\(size) pt at \(stock.window.backingScaleFactor)x"
                #expect(bar.frame.width == 2, "\(label): \(bar.frame)")
                #expect(bar.frame.midX == 0, "\(label): \(bar.frame)")
                #expect(bar.frame.height == stock.indicator?.frame.height, "\(label): \(bar.frame)")
            }
        }
    }

    /// S5: the streak's spring on a four-point path keeps four corners, moves only the trailing two, reaches 91%
    /// of the way at T = 0.12 s and 98% at 1.46T without overshoot, and its opacity is gone by 0.165 s. Layer time is
    /// frozen and stepped, and the presentation layer read at each step.
    @Test(arguments: [(NSRect(x: 10, y: 10, width: 2, height: 20), NSRect(x: 210, y: 10, width: 2, height: 20)),
                      (NSRect(x: 40, y: 10, width: 2, height: 20), NSRect(x: 40, y: 110, width: 2, height: 20))])
    func s5SpringPathConverges(_ old: NSRect, _ new: NSRect) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView()
        content.wantsLayer = true
        window.contentView = content
        let clock = CALayer()
        clock.speed = 0
        let streak = CAShapeLayer()
        clock.addSublayer(streak)
        try #require(content.layer).addSublayer(clock)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        streak.path = CGPath(rect: new, transform: nil)
        streak.opacity = 0
        streak.add(CaretEffectsView.streakAnimation(from: old, to: new), forKey: "streak")
        CATransaction.commit()
        CATransaction.flush()
        let end = [CGPoint(x: new.minX, y: new.minY), CGPoint(x: new.maxX, y: new.minY), CGPoint(x: new.maxX, y: new.maxY), CGPoint(x: new.minX, y: new.maxY)]
        let start = end.map { CGPoint(x: $0.x - (new.minX - old.minX), y: $0.y - (new.minY - old.minY)) }
        let leading = end.indices.filter { (end[$0].x - new.midX) * (new.midX - old.midX) + (end[$0].y - new.midY) * (new.midY - old.midY) > 0 }
        #expect(leading.count == 2)
        var progress: [Double] = []
        for time in stride(from: 0.0, through: 0.35, by: 0.005) {
            clock.timeOffset = time
            CATransaction.flush()
            let frame = try #require(streak.presentation())
            let points = corners(frame.path)
            try #require(points.count == 4, "t = \(time): \(points)")
            for index in leading { #expect(points[index] == end[index], "t = \(time), leading corner \(index)") }
            let trailing = try #require(end.indices.first { !leading.contains($0) })
            let travel = hypot(end[trailing].x - start[trailing].x, end[trailing].y - start[trailing].y)
            progress.append(hypot(points[trailing].x - start[trailing].x, points[trailing].y - start[trailing].y) / travel)
            #expect(time < 0.17 || frame.opacity == 0, "t = \(time): opacity \(frame.opacity)")
        }
        let omega = 1111.0.squareRoot()
        for (step, value) in progress.enumerated() where step < 60 {
            let time = Double(step) * 0.005
            let critical = 1 - (1 + omega * time) * exp(-omega * time)
            #expect(abs(value - critical) < 0.003, "t = \(time): \(value), critically damped \(critical)")
        }
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } && progress.allSatisfy { $0 <= 1 + 1e-9 })
        #expect(progress[24] > 0.9 && progress[35] > 0.979 && progress[60] > 0.999, "T: \(progress[24]), 1.46T: \(progress[35]), 2.5T: \(progress[60])")
        #expect(progress.last == 1)
    }
}
