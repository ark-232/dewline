import AppKit
import ObjectiveC

/// Keeps a test's windows off the screen: while installed, ordering a window in, making it key or main, and
/// activating the app only record the call. NSApp's main, key and ordered windows answer with `main`. Windows still
/// lay out and draw, so a test can read their views or draw them to an image.
enum Offscreen {
    struct Placement {
        let window: NSWindow
        let place: NSWindow.OrderingMode
        let relativeTo: Int
    }

    nonisolated(unsafe) static var ordered: [NSWindow] = []
    nonisolated(unsafe) static var placed: [Placement] = []
    nonisolated(unsafe) static var main: NSWindow?
    nonisolated(unsafe) private static var saved: [(Method, IMP)] = []
    nonisolated(unsafe) private static var depth = 0

    private static func replace(_ cls: AnyClass, _ name: String, _ block: Any) {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { return }
        saved.append((method, method_setImplementation(method, imp_implementationWithBlock(block))))
    }

    static func install() {
        depth += 1
        guard depth == 1 else { return }
        let record: @convention(block) (NSWindow, AnyObject?) -> Void = { window, _ in ordered.append(window) }
        let recordBare: @convention(block) (NSWindow) -> Void = { window in ordered.append(window) }
        let order: @convention(block) (NSWindow, Int, Int) -> Void = { window, place, other in
            placed.append(Placement(window: window, place: NSWindow.OrderingMode(rawValue: place) ?? .out, relativeTo: other))
        }
        for name in ["orderFront:", "makeKeyAndOrderFront:", "orderBack:"] { replace(NSWindow.self, name, record) }
        for name in ["orderFrontRegardless", "makeKeyWindow", "makeMainWindow"] { replace(NSWindow.self, name, recordBare) }
        replace(NSWindow.self, "orderWindow:relativeTo:", order)
        let window: @convention(block) (NSApplication) -> NSWindow? = { _ in main }
        replace(NSApplication.self, "mainWindow", window)
        replace(NSApplication.self, "keyWindow", window)
        let windows: @convention(block) (NSApplication) -> NSArray = { _ in (main.map { [$0] } ?? []) as NSArray }
        replace(NSApplication.self, "orderedWindows", windows)
        let activate: @convention(block) (NSApplication, Bool) -> Void = { _, _ in }
        replace(NSApplication.self, "activateIgnoringOtherApps:", activate)
        let activateBare: @convention(block) (NSApplication) -> Void = { _ in }
        replace(NSApplication.self, "activate", activateBare)
    }

    static func uninstall() {
        depth -= 1
        guard depth == 0 else { return }
        for (method, imp) in saved.reversed() { method_setImplementation(method, imp) }
        saved = []
        ordered = []
        placed = []
        main = nil
    }
}
