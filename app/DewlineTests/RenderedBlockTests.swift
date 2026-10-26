import AppKit
import Testing
@testable import Dewline

/// An editor in a window that is never ordered front, waiting for its pictures.
@MainActor
private struct BlockEditor {
    let variant: TextKitVariant
    let window: NSWindow
    let view: EditorTextView

    init(_ variant: TextKitVariant, _ text: String, caret: Int, folder: URL? = nil) {
        self.variant = variant
        let scrollView = EditorTextView.scrollView(variant: variant)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        view = scrollView.documentView as! EditorTextView
        view.documentFolder = folder
        view.string = text
        window.makeFirstResponder(view)
        place(caret)
    }

    func place(_ caret: Int) {
        view.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func rect(_ location: Int, _ length: Int) -> NSRect {
        view.firstRect(forCharacterRange: NSRange(location: location, length: length), actualRange: nil)
    }

    /// How the line at `location` draws, if it belongs to a block that draws.
    func role(at location: Int) -> BlockLine.Role? {
        (view.textStorage!.attribute(.dewlineBlock, at: location, effectiveRange: nil) as? BlockLine)?.role
    }

    func picture(at location: Int) -> BlockPicture? {
        guard case .picture(let picture, _)? = role(at: location) else { return nil }
        return picture
    }

    func error(at location: Int) -> String? {
        guard case .error(let message)? = role(at: location) else { return nil }
        return message
    }

    /// Lets the main queue deliver pictures until `done` holds, for at most five seconds.
    func wait(until done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func expectTextKitUnchanged() {
        #expect((view.textLayoutManager != nil) == (variant == .textKit2))
    }
}

@MainActor
struct RenderedBlockTests {
    static let diagram = "```mermaid\nflowchart LR\n  a[Start] --> b[Stop]\n```"
    static let formula = "$$\n\\frac{a}{b} + \\sqrt{x}\n$$"
    static let picturePath = "dot.png"

    /// A folder holding a 300 by 120 pixel PNG named `dot.png`.
    static func imageFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-blocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 300, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 120))
        let image = try #require(context.makeImage())
        let file: URL = folder.appending(path: picturePath)
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return folder
    }

    @Test(arguments: TextKitVariant.allCases)
    func collapsedBlocksTakeThePicturesHeight(_ variant: TextKitVariant) async throws {
        let folder = try Self.imageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for block in [Self.diagram, Self.formula, "![a dot](\(Self.picturePath))"] {
            let text = "Above\n\n\(block)\n\nBelow\n"
            let start = 7
            let below = text.utf16.count - 6
            let editor = BlockEditor(variant, text, caret: 0, folder: folder)
            await editor.wait { editor.picture(at: start) != nil }
            let picture = try #require(editor.picture(at: start), "\(block)")
            let plain = BlockEditor(variant, "Above\n\n\nBelow\n", caret: 0)
            let height = editor.rect(0, 1).minY - editor.rect(below, 1).maxY - (plain.rect(0, 1).minY - plain.rect(8, 1).maxY)
            #expect(abs(height - picture.size.height) <= 1, "\(block): block is \(height) pt, picture \(picture.size.height) pt")
            let moved = plain.rect(8, 1).maxY - editor.rect(below, 1).maxY
            #expect(abs(moved - picture.size.height) <= 1, "\(block): lines below moved \(moved) pt")
            editor.expectTextKitUnchanged()
        }
    }

    @Test(arguments: TextKitVariant.allCases)
    func renderingNeverChangesTheString(_ variant: TextKitVariant) async throws {
        let text = "Notes\n\n\(Self.diagram)\n\n\(Self.formula)\n\n![a dot](\(Self.picturePath))\n\nEnd\n"
        let starts = [Self.diagram, Self.formula, "![a dot]"].map { (text as NSString).range(of: $0).location }
        let folder = try Self.imageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = BlockEditor(variant, text, caret: 0, folder: folder)
        await editor.wait { starts.allSatisfy { editor.picture(at: $0) != nil } }
        #expect(starts.allSatisfy { editor.picture(at: $0) != nil })
        #expect(editor.view.string == text)
        for caret in 0...text.utf16.count {
            editor.place(caret)
            #expect(editor.view.string == text)
        }
        editor.place((text as NSString).range(of: "Stop").location)
        editor.view.insertText("Go ", replacementRange: editor.view.selectedRange())
        let edited = text.replacingOccurrences(of: "[Stop]", with: "[Go Stop]")
        #expect(editor.view.string == edited)
        editor.place(0)
        await editor.wait { editor.picture(at: starts[0]) != nil }
        #expect(editor.picture(at: starts[0]) != nil)
        #expect(editor.view.string == edited)
        editor.view.styler.undoManager.endUndoGrouping()
        editor.window.tryToPerform(Selector(("undo:")), with: nil)
        #expect(editor.view.string == text)
        editor.place(0)
        await editor.wait { editor.picture(at: starts[0]) != nil }
        #expect(editor.picture(at: starts[0]) != nil, "the first picture comes back")
        #expect(editor.view.string == text)
        editor.expectTextKitUnchanged()
    }

    /// Light and dark take the light and dark slots' themes, so switching the window's appearance changes the theme
    /// without touching the owner's defaults.
    @Test(arguments: TextKitVariant.allCases)
    func blocksRedrawInTheThemeOfEachAppearance(_ variant: TextKitVariant) async {
        let text = "Above\n\(Self.diagram)\n\(Self.formula)\nBelow"
        let diagram = 6
        let formula = diagram + Self.diagram.utf16.count + 1
        let editor = BlockEditor(variant, text, caret: 0)
        let store = ThemeStore.shared
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        var drawn: [CGImage] = []
        for (name, tokens) in [
            (NSAppearance.Name.aqua, increased ? store.lightTheme.increasedLightColors : store.lightTheme.lightColors),
            (.darkAqua, increased ? store.darkTheme.increasedDarkColors : store.darkTheme.darkColors),
        ] {
            func rgb(_ token: Token) -> [Int] {
                let color = tokens[token]!.usingColorSpace(.sRGB)!
                return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
            }
            // The diagram's top-left pixel, and the formula's most opaque pixel unpremultiplied.
            func colors() -> (paper: [Int], ink: [Int])? {
                guard let chart = editor.picture(at: diagram), let math = editor.picture(at: formula) else { return nil }
                let pixels = Self.pixels(math.image)
                let solid = stride(from: 0, to: pixels.count, by: 4).max { pixels[$0 + 3] < pixels[$1 + 3] }!
                let ink = pixels[solid..<solid + 3].map { Int((Double($0) * 255 / Double(pixels[solid + 3])).rounded()) }
                return (Self.pixels(chart.image)[0..<3].map(Int.init), ink)
            }
            func taken() -> Bool {
                guard case let (paper, ink)? = colors() else { return false }
                return paper == rgb(.paper) && zip(ink, rgb(.ink)).allSatisfy { abs($0 - $1) <= 2 }
            }
            editor.window.appearance = NSAppearance(named: name)
            await editor.wait(until: taken)
            #expect(taken(), "\(name.rawValue): paper \(rgb(.paper)) and ink \(rgb(.ink)), drawn \(String(describing: colors()))")
            drawn += [diagram, formula].compactMap { editor.picture(at: $0)?.image }
        }
        #expect(drawn.count == 4 && drawn[0] !== drawn[2] && drawn[1] !== drawn[3], "the light pictures are replaced")
        editor.expectTextKitUnchanged()
    }

    /// The image drawn in sRGB as premultiplied RGBA, row by row from the top.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    @Test(arguments: TextKitVariant.allCases)
    func theCaretRevealsTheSource(_ variant: TextKitVariant) async {
        let text = "Above\n\(Self.diagram)\nBelow"
        let start = 6
        let end = start + Self.diagram.utf16.count
        let editor = BlockEditor(variant, text, caret: 0)
        await editor.wait { editor.picture(at: start) != nil }
        let moves = [
            (editor.view.moveRight, Array((start - 1)...(end + 1))),
            (editor.view.moveLeft, Array((start - 1)...(end + 1)).reversed()),
        ]
        for (move, path) in moves {
            editor.place(path[0])
            #expect(editor.picture(at: start) != nil)
            var visited = [path[0]]
            for _ in 1..<path.count {
                move(nil)
                let caret = editor.view.selectedRange().location
                visited.append(caret)
                let inside = (start...end).contains(caret)
                #expect((editor.picture(at: start) == nil) == inside, "caret at \(caret)")
                if inside {
                    #expect(editor.rect(start, 3).width > 2, "the fence shows with the caret at \(caret)")
                }
            }
            #expect(visited == path)
        }
        // Undoing an edit above a revealed block moves the block; in TextKit 1 it also takes the caret to the edit.
        editor.place(0)
        editor.view.insertText("x", replacementRange: editor.view.selectedRange())
        editor.place(start + 4)
        #expect(editor.picture(at: start + 1) == nil)
        editor.view.styler.undoManager.endUndoGrouping()
        editor.window.tryToPerform(Selector(("undo:")), with: nil)
        #expect(editor.view.string == text)
        editor.place(0)
        #expect(editor.picture(at: start) != nil, "the picture returns once the caret is out")
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func sourceModeShowsEveryBlocksSource(_ variant: TextKitVariant) async {
        let text = "Above\n\(Self.diagram)\n\(Self.formula)\nBelow"
        let diagram = 6
        let formula = diagram + Self.diagram.utf16.count + 1
        let editor = BlockEditor(variant, text, caret: 0)
        await editor.wait { editor.picture(at: diagram) != nil && editor.picture(at: formula) != nil }
        editor.view.toggleSource(nil)
        #expect(editor.picture(at: diagram) == nil && editor.picture(at: formula) == nil)
        #expect(editor.rect(diagram, 3).width > 2 && editor.rect(formula, 2).width > 2, "both blocks show their source")
        editor.view.toggleSource(nil)
        #expect(editor.picture(at: diagram) != nil && editor.picture(at: formula) != nil, "the cached pictures return in Live")
        #expect(editor.view.string == text)
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func copyingTakesTheSource(_ variant: TextKitVariant) async {
        let text = "Above\n\(Self.diagram)\nBelow"
        let editor = BlockEditor(variant, text, caret: 0)
        await editor.wait { editor.picture(at: 6) != nil }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arkwerx.dewline.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        for selection in [NSRange(location: 2, length: text.utf16.count - 4), NSRange(location: 0, length: text.utf16.count)] {
            editor.view.setSelectedRange(selection)
            #expect(editor.view.writeSelection(to: pasteboard, types: editor.view.writablePasteboardTypes))
            #expect(pasteboard.string(forType: .string) == (text as NSString).substring(with: selection))
        }
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func accessibilityReadsTheSourceAndLabelsThePictures(_ variant: TextKitVariant) async {
        let text = "Above\n\(Self.diagram)\n\n\(Self.formula)\nBelow"
        let starts = [Self.diagram, Self.formula].map { (text as NSString).range(of: $0).location }
        let editor = BlockEditor(variant, text, caret: 0)
        await editor.wait { starts.allSatisfy { editor.picture(at: $0) != nil } }
        #expect(editor.view.accessibilityValue() == text)
        let images = (editor.view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
            .filter { $0.accessibilityRole() == .image }
        #expect(images.map { $0.accessibilityLabel() } == ["flowchart LR", "\\frac{a}{b} + \\sqrt{x}"])
        #expect(images.allSatisfy { $0.accessibilityFrame().width > 0 && $0.accessibilityFrame().height > 0 })
        #expect(abs(images[0].accessibilityFrame().maxY - editor.rect(0, 1).minY) <= 0.5, "the diagram's frame starts under its first line")
        editor.expectTextKitUnchanged()
    }

    @Test(arguments: TextKitVariant.allCases)
    func brokenBlocksShowTheSourceAndTheErrorWithoutBlockingTyping(_ variant: TextKitVariant) async {
        let broken = "```mermaid\nnot a diagram\n```"
        let text = "Above\n\(broken)\nBetween\n$$\\frac{a$$\nBelow"
        let fence = 6
        let closing = fence + broken.utf16.count - 3
        let tex = (text as NSString).range(of: "$$").location
        let editor = BlockEditor(variant, text, caret: text.utf16.count)
        // Typing goes on while the pictures render.
        let clock = ContinuousClock()
        for character in ["!", "?"] {
            let elapsed = clock.measure { editor.view.insertText(character, replacementRange: editor.view.selectedRange()) }
            #expect(elapsed < .milliseconds(100), "typing took \(elapsed)")
        }
        #expect(editor.view.string == text + "!?")
        await editor.wait { editor.error(at: closing) != nil && editor.error(at: tex) != nil }
        #expect(editor.error(at: closing)?.hasPrefix("Mermaid: ") == true, "\(editor.error(at: closing) ?? "no error")")
        #expect(editor.error(at: tex)?.hasPrefix("TeX: ") == true, "\(editor.error(at: tex) ?? "no error")")
        #expect(editor.picture(at: fence) == nil && editor.picture(at: tex) == nil)
        #expect(editor.rect(fence, 3).width > 2 && editor.rect(tex, 2).width > 2, "the source shows")
        let between = closing + 4
        let gap = editor.rect(closing, 3).minY - editor.rect(between, 1).maxY
        #expect(abs(gap - BlockLine.errorHeight) <= 0.5, "the error line is \(gap) pt")
        editor.place((text as NSString).range(of: "a diagram").location)
        editor.view.insertText("x", replacementRange: editor.view.selectedRange())
        #expect(editor.view.string == text.replacingOccurrences(of: "not a", with: "not xa") + "!?")
        editor.expectTextKitUnchanged()
    }
}
