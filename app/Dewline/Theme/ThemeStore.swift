import AppKit
import Observation

/// The owner's look, kept in user defaults: a theme for the light slot and one for the dark, which appearance windows
/// take, and the page's faces, size, leading, measure and heading style. Posts `didChange` after every change.
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
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "Dewline" + key)
        colors = [:]
        headings = [:]
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

    var bodyFont: NSFont {
        Faces.font(bodyFace, size: bodySize)
    }

    /// The body's line height, on the half-point grid.
    var bodyLineHeight: CGFloat {
        (bodySize * lineHeight * 2).rounded() / 2
    }

    /// The text column's width: `columnWidth` times the body font's average advance over the lowercase alphabet and
    /// the space.
    var measure: CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyz "
        let width = NSAttributedString(string: sample, attributes: [.font: bodyFont]).size().width
        return (width / CGFloat(sample.count) * columnWidth).rounded()
    }

    func codeFont(size: CGFloat) -> NSFont {
        Faces.font(codeFace, size: size)
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

    static func exists(_ family: String) -> Bool {
        design(family) != nil || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
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
