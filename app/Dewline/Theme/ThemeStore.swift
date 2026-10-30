import AppKit
import Observation

/// The owner's look, kept in user defaults: a theme for the light slot and one for the dark, which appearance windows
/// take, the page's faces, size, leading, measure and heading style, and Smart Punctuation. Posts `didChange` after
/// every change.
@MainActor @Observable
final class ThemeStore {
    enum Appearance: String, CaseIterable, Identifiable {
        case light, dark, auto
        var id: Self { self }
    }

    enum HeadingStyle: String {
        case standard, editorial
    }

    static let shared: ThemeStore = {
        FontLibrary.waitForLaunchRegistration()
        let store = ThemeStore(defaults: .standard)
        store.applyAppearance()
        return store
    }()

    static let didChange = Notification.Name("DewlineThemeDidChange")
    static let bodySizes = 12.0...28.0
    static let lineHeights = 1.25...1.8
    static let columnWidths = 50.0...90.0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var colors: [Token: NSColor] = [:]
    @ObservationIgnored private var headings: [Int: Heading] = [:]
    @ObservationIgnored private var body: NSFont?
    @ObservationIgnored private var code: [CGFloat: NSFont] = [:]
    @ObservationIgnored private var traited: [NSFont: [UInt32: NSFont]] = [:]
    @ObservationIgnored private var lines: [CGFloat: NSParagraphStyle] = [:]
    @ObservationIgnored private var quote: NSParagraphStyle?
    @ObservationIgnored private var writerColors: [Writer: NSColor] = [:]

    var appearance: Appearance {
        didSet {
            save(appearance.rawValue, "Appearance")
            applyAppearance()
        }
    }
    var lightTheme: Theme { didSet { save(lightTheme.name, "LightTheme") } }
    var darkTheme: Theme { didSet { save(darkTheme.name, "DarkTheme") } }
    var bodyFace: String { didSet { save(bodyFace, "BodyFace") } }
    var headingFace: String { didSet { save(headingFace, "HeadingFace") } }
    var codeFace: String { didSet { save(codeFace, "CodeFace") } }
    var bodySize: Double { didSet { save(bodySize, "BodySize") } }
    var lineHeight: Double { didSet { save(lineHeight, "LineHeight") } }
    var columnWidth: Double { didSet { save(columnWidth, "ColumnWidth") } }
    var headingStyle: HeadingStyle { didSet { save(headingStyle.rawValue, "HeadingStyle") } }
    var vimMode: Bool { didSet { save(vimMode, "VimMode") } }
    /// The system's smart quotes and dashes, outside code; off by default.
    var smartPunctuation: Bool { didSet { save(smartPunctuation, "SmartPunctuation") } }
    /// The hues the owner picked, by writer, as chroma and hue; a writer without one keeps its default.
    var writerHues: [Writer: OKLCH] {
        didSet { save(Dictionary(uniqueKeysWithValues: writerHues.map { ($0.key.rawValue, [$0.value.c, $0.value.h]) }), "WriterHues") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func string(_ key: String) -> String? { defaults.string(forKey: "Dewline" + key) }
        func face(_ key: String) -> String? { string(key).flatMap { Faces.exists($0) ? $0 : nil } }
        func number(_ key: String, in range: ClosedRange<Double>) -> Double? {
            (defaults.object(forKey: "Dewline" + key) as? Double).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        appearance = string("Appearance").flatMap(Appearance.init) ?? .auto
        lightTheme = string("LightTheme").flatMap(Theme.named) ?? .tidewater
        darkTheme = string("DarkTheme").flatMap(Theme.named) ?? .nightwatch
        bodyFace = face("BodyFace") ?? Faces.body
        headingFace = face("HeadingFace") ?? Faces.heading
        codeFace = face("CodeFace") ?? Faces.code
        bodySize = number("BodySize", in: Self.bodySizes) ?? 17
        lineHeight = number("LineHeight", in: Self.lineHeights) ?? 1.44
        columnWidth = number("ColumnWidth", in: Self.columnWidths) ?? 68
        headingStyle = string("HeadingStyle").flatMap(HeadingStyle.init) ?? .standard
        vimMode = defaults.bool(forKey: "DewlineVimMode")
        smartPunctuation = defaults.bool(forKey: "DewlineSmartPunctuation")
        let hues = defaults.dictionary(forKey: "DewlineWriterHues") as? [String: [Double]] ?? [:]
        writerHues = hues.reduce(into: [:]) { picks, entry in
            guard let writer = Writer(rawValue: entry.key), entry.value.count == 2 else { return }
            picks[writer] = OKLCH(l: writer.standard.light.l, c: entry.value[0], h: entry.value[1])
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "Dewline" + key)
        colors = [:]
        headings = [:]
        body = nil
        code = [:]
        traited = [:]
        lines = [:]
        quote = nil
        writerColors = [:]
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .auto: nil
        }
    }

    /// The token in the light slot's theme under a light appearance and the dark slot's under a dark one, raised under
    /// Increase Contrast. The sky falls back to `sidebarTint` in themes without one.
    func color(_ token: Token) -> NSColor {
        if let color = colors[token] { return color }
        func pick(_ colors: [Token: NSColor]) -> NSColor {
            colors[token] ?? colors[.sidebarTint]!
        }
        let light = pick(lightTheme.lightColors)
        let dark = pick(darkTheme.darkColors)
        let increasedLight = pick(lightTheme.increasedLightColors)
        let increasedDark = pick(darkTheme.increasedDarkColors)
        let color = NSColor(name: nil) {
            switch $0.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: dark
            case .accessibilityHighContrastAqua?: increasedLight
            case .accessibilityHighContrastDarkAqua?: increasedDark
            default: light
            }
        }
        colors[token] = color
        return color
    }

    /// The writer's mark color under the window's appearance (D21): the owner's hue when there is one.
    func writerColor(_ writer: Writer) -> NSColor {
        // Read on a cache hit too, so a view that shows the color observes it.
        let pick = writerHues[writer]
        if let color = writerColors[writer] { return color }
        let colors = writer.colors(pick)
        let (light, dark) = (colors.light.color, colors.dark.color)
        let color = NSColor(name: nil) { $0.isDark ? dark : light }
        writerColors[writer] = color
        return color
    }

    /// The theme color within ΔE 8 of `writer`'s, nearest first, across the light slot's light tokens and the dark
    /// slot's dark ones. A gray token never clashes with a gray writer: their shapes tell them apart.
    func clash(_ writer: Writer) -> WriterClash? {
        let colors = writer.colors(writerHues[writer])
        func nearest(_ colors: (light: OKLCH, dark: OKLCH)) -> (theme: Theme, token: Token, dark: Bool, deltaE: Double)? {
            var best: (theme: Theme, token: Token, dark: Bool, deltaE: Double)?
            for (theme, dark, color) in [(lightTheme, false, colors.light), (darkTheme, true, colors.dark)] {
                for (token, value) in dark ? theme.dark : theme.light where value.c >= 0.03 || color.c >= 0.03 {
                    let deltaE = value.deltaE(color)
                    if deltaE < best?.deltaE ?? .infinity { best = (theme, token, dark, deltaE) }
                }
            }
            return best
        }
        guard let near = nearest(colors), near.deltaE < WriterClash.distance else { return nil }
        var clear: OKLCH?
        if colors.light.c >= 0.03 {
            search: for step in 1...180 {
                for hue in [colors.light.h + Double(step), colors.light.h - Double(step)] {
                    let candidate = OKLCH(l: colors.light.l, c: colors.light.c, h: (hue + 360).truncatingRemainder(dividingBy: 360))
                    if let other = nearest(writer.colors(candidate)), other.deltaE >= WriterClash.distance {
                        clear = candidate
                        break search
                    }
                }
            }
        }
        return WriterClash(theme: near.theme, token: near.token, dark: near.dark, deltaE: near.deltaE, clearHue: clear)
    }

    /// The backdrop of the slot's theme for a light or dark appearance, under the system's accessibility settings.
    func backdrop(dark: Bool) -> (tint: OKLCH, sky: [OKLCH]) {
        let workspace = NSWorkspace.shared
        return (dark ? darkTheme : lightTheme).backdrop(
            dark: dark,
            increasedContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reducedTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        )
    }

    var bodyFont: NSFont {
        // Read on a cache hit too, so a view that shows the font observes them.
        let face = bodyFace, size = bodySize
        if let body { return body }
        let font = Faces.font(face, size: size)
        body = font
        return font
    }

    /// The body's line height, on the half-point grid.
    var bodyLineHeight: CGFloat {
        (bodySize * lineHeight * 2).rounded() / 2
    }

    /// A paragraph style whose lines are all `height` tall.
    func paragraphStyle(lineHeight height: CGFloat) -> NSParagraphStyle {
        if let style = lines[height] { return style }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        lines[height] = style
        return style
    }

    /// The body's paragraph style, indented for a quote.
    var quoteParagraphStyle: NSParagraphStyle {
        if let quote { return quote }
        let style = paragraphStyle(lineHeight: bodyLineHeight).mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = (18 * bodySize / 17).rounded()
        style.headIndent = style.firstLineHeadIndent
        quote = style
        return style
    }

    /// The text column's width: `columnWidth` times the body font's average advance over the lowercase alphabet and
    /// the space.
    var measure: CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyz "
        let width = NSAttributedString(string: sample, attributes: [.font: bodyFont]).size().width
        return (width / CGFloat(sample.count) * columnWidth).rounded()
    }

    /// Puts every slot that uses `family` back on its default, before the family is removed; returns the slots' names.
    func release(_ family: String) -> [String] {
        var slots: [String] = []
        if bodyFace == family {
            bodyFace = Faces.body
            slots.append("Body")
        }
        if headingFace == family {
            headingFace = Faces.heading
            slots.append("Headings")
        }
        if codeFace == family {
            codeFace = Faces.code
            slots.append("Code")
        }
        return slots
    }

    func codeFont(size: CGFloat) -> NSFont {
        // Read on a cache hit too, so a view that shows the font observes it.
        let face = codeFace
        if let font = code[size] { return font }
        let font = Faces.font(face, size: size)
        code[size] = font
        return font
    }

    func font(_ font: NSFont, adding traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        if let derived = traited[font]?[traits.rawValue] { return derived }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        let derived = NSFont(descriptor: descriptor, size: font.pointSize)!
        traited[font, default: [:]][traits.rawValue] = derived
        return derived
    }

    struct Heading {
        let font: NSFont
        let lineHeight: CGFloat
        let kern: CGFloat
    }

    /// Heading levels 1 to 6 (synthesis 2.3), scaled with the body size. Editorial sets the title large and section
    /// heads in small caps.
    func heading(_ level: Int) -> Heading {
        if let heading = headings[level] { return heading }
        let scale = bodySize / 17
        func smallCaps(_ font: NSFont) -> NSFont {
            let features: [[NSFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
                [.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector],
            ]
            return NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: features]), size: font.pointSize)!
        }
        let heading = switch (level, headingStyle) {
        case (1, .editorial):
            Heading(font: Faces.font(headingFace, size: 44 * scale), lineHeight: 50 * scale, kern: 0)
        case (2, .editorial):
            Heading(font: smallCaps(Faces.font(headingFace, size: 15 * scale, weight: .medium)), lineHeight: 25 * scale, kern: 0.75 * scale)
        case (1, _):
            Heading(font: Faces.font(headingFace, size: 32 * scale, weight: .medium), lineHeight: 38 * scale, kern: 0)
        case (2, _):
            Heading(font: Faces.font(headingFace, size: 24 * scale, weight: .medium), lineHeight: 30 * scale, kern: 0)
        case (3, _):
            Heading(font: Faces.font(headingFace, size: 19 * scale, weight: .semibold), lineHeight: 26 * scale, kern: 0)
        default:
            Heading(font: Faces.font(bodyFace, size: bodySize, weight: .semibold), lineHeight: bodyLineHeight, kern: 0)
        }
        headings[level] = heading
        return heading
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Three faces chosen together in the Fonts pane (synthesis 2.8); one click sets all three slots, installing any
/// catalog family they need first.
struct Pairing: Identifiable {
    let name: String
    let body: String
    let heading: String
    let code: String

    var id: String { name }
    /// Each face once, headings first.
    var faces: [String] { [heading, body, code].reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    /// The catalog families among them that aren't installed yet.
    var missing: [FontCatalog.Family] { faces.filter { !Faces.exists($0) }.compactMap(FontCatalog.family) }

    static let all = [
        Pairing(name: "Editorial", body: "New York", heading: "Newsreader", code: "JetBrains Mono"),
        Pairing(name: "Manuscript", body: "Courier Prime", heading: "Courier Prime", code: "Courier Prime"),
        Pairing(name: "Hyperlegible", body: "Atkinson Hyperlegible Next", heading: "Atkinson Hyperlegible Next", code: "Atkinson Hyperlegible Mono"),
    ]
}

/// Faces by family name, where New York, SF Pro, SF Pro Rounded and SF Mono name the system designs.
enum Faces {
    static let body = "New York"
    static let heading = "New York"
    static let code = "JetBrains Mono"
    static let system = ["New York", "SF Pro", "SF Pro Rounded", "SF Mono"]
    static let bundled = ["JetBrains Mono"]

    private static func design(_ family: String) -> NSFontDescriptor.SystemDesign? {
        switch family {
        case "New York": .serif
        case "SF Pro": .default
        case "SF Pro Rounded": .rounded
        case "SF Mono": .monospaced
        default: nil
        }
    }

    /// CoreText sees a font registered for the process at once; NSFontManager's lists catch up a run loop later.
    static func exists(_ family: String) -> Bool {
        design(family) != nil || !faces(of: family).isEmpty
    }

    static func faces(of family: String) -> [CTFontDescriptor] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        return CTFontDescriptorCreateMatchingFontDescriptors(descriptor, [kCTFontFamilyNameAttribute as String] as Set<String> as CFSet) as? [CTFontDescriptor] ?? []
    }

    /// Installed families other than the system's hidden ones, by name; `monospaced` keeps the fixed-pitch ones.
    static func installed(monospaced: Bool) -> [String] {
        let manager = NSFontManager.shared
        let families = monospaced
            ? Set(manager.availableFontNames(with: .fixedPitchFontMask)?.compactMap { NSFont(name: $0, size: 12)?.familyName } ?? [])
            : Set(manager.availableFontFamilies)
        return families.filter { !$0.hasPrefix(".") && !bundled.contains($0) }.sorted()
    }

    static func font(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let design = design(family) {
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(design)!
            return NSFont(descriptor: descriptor, size: size)!
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        return NSFont(descriptor: descriptor, size: size)!
    }
}
