import AppKit
import Testing
@testable import Dewline

struct ThemeTests {
    /// Gamma-encoded components in the color's own space, sRGB or Display P3.
    private func components(_ color: NSColor) -> [Double] {
        [color.redComponent, color.greenComponent, color.blueComponent].map(Double.init)
    }

    @Test func oklchConvertsToSRGBAndDisplayP3() {
        // References computed through CIE XYZ with the CSS Color 4 matrices.
        let srgb: [(OKLCH, [Double])] = [
            (OKLCH(l: 1, c: 0, h: 0), [1, 1, 1]),
            (OKLCH(l: 0, c: 0, h: 0), [0, 0, 0]),
            (OKLCH(l: 0.6279553606, c: 0.2576833077, h: 29.2338851923), [1, 0, 0]),
            (OKLCH(l: 0.50, c: 0.20, h: 266), [0.176436, 0.329970, 0.826868]),
            (OKLCH(l: 0.80, c: 0.15, h: 155), [0.378526, 0.853859, 0.573974]),
        ]
        for (oklch, expected) in srgb {
            let color = oklch.color
            #expect(color.colorSpace == .sRGB, "\(oklch)")
            #expect(zip(components(color), expected).allSatisfy { abs($0 - $1) < 0.0005 }, "\(oklch): \(components(color))")
        }
        let wide = OKLCH(l: 0.65, c: 0.22, h: 145).color
        #expect(wide.colorSpace == .displayP3)
        #expect(zip(components(wide), [0.271949, 0.675031, 0.229157]).allSatisfy { abs($0 - $1) < 0.0005 }, "\(components(wide))")
    }

    @Test func everyThemeDefinesEveryToken() {
        #expect(Theme.all.map(\.name) == ["Tidewater", "Aurora", "Dawnline", "Dusk", "Nightwatch", "Carbon"])
        for theme in Theme.all {
            for (appearance, tokens) in [("light", theme.light), ("dark", theme.dark)] {
                for token in Token.required {
                    #expect(tokens[token] != nil, "\(theme.name) \(appearance) has no \(token)")
                }
                #expect((tokens[.sky1] == nil) == (tokens[.sky2] == nil), "\(theme.name) \(appearance) has half a sky")
            }
            #expect(Set(theme.light.keys) == Set(theme.dark.keys), "\(theme.name)")
            #expect(Set(theme.lightColors.keys) == Set(theme.light.keys) && Set(theme.darkColors.keys) == Set(theme.dark.keys))
        }
        #expect(Theme.all.filter(\.hasSky).map(\.name) == ["Dusk", "Nightwatch"])
    }

    @MainActor @Test func choicesPersistAndPost() throws {
        let suite = "dev.arkwerx.dewline.tests.themes"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(defaults: defaults)
        #expect(store.lightTheme == .tidewater && store.darkTheme == .nightwatch && store.appearance == .auto)
        let listener = Listener()
        NotificationCenter.default.addObserver(listener, selector: #selector(Listener.changed), name: ThemeStore.didChange, object: store)
        store.lightTheme = .dawnline
        store.darkTheme = .carbon
        store.bodySize = 40
        store.columnWidth = 76
        #expect(listener.posts == 4)
        let reloaded = ThemeStore(defaults: defaults)
        #expect(reloaded.lightTheme == .dawnline && reloaded.darkTheme == .carbon)
        #expect(reloaded.bodySize == ThemeStore.bodySizes.upperBound && reloaded.columnWidth == 76)
    }
}

@MainActor
private final class Listener: NSObject {
    var posts = 0

    @objc func changed(_ notification: Notification) {
        posts += 1
    }
}
