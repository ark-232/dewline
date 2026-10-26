import AppKit
import Testing
@testable import Dewline

/// A window that reports itself key without being ordered front, so a text view in it builds and drives the system
/// insertion indicator.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
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
        for (appearance, expected) in [(NSAppearance.Name.aqua, [0.1764, 0.33, 0.8269]), (.darkAqua, [0.5182, 0.6583, 0.9922])] {
            stock.window.appearance = NSAppearance(named: appearance)
            stock.settle()
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
}
