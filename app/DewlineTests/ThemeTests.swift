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

    @Test func textMeetsContrastInEveryVariant() {
        for theme in Theme.all {
            for (dark, authored) in [(false, theme.light), (true, theme.dark)] {
                for (variant, tokens) in [("authored", authored), ("increased", Theme.increased(authored, dark: dark))] {
                    let paper = tokens[.paper]!
                    let label = "\(theme.name) \(dark ? "dark" : "light") \(variant)"
                    for token in [Token.ink, .ink2, .heading, .link] {
                        #expect(tokens[token]!.contrast(with: paper) >= 4.5, "\(label) \(token)")
                    }
                    #expect(tokens[.syntax]!.contrast(with: paper) >= 3, "\(label) syntax")
                    #expect(tokens[.accent]!.contrast(with: paper) >= 3, "\(label) accent")
                    #expect(tokens[.ink]!.contrast(with: tokens[.selection]!) >= 4.5, "\(label) ink on selection")
                }
            }
        }
    }

    @Test func backdropIsTheTintUnderASkyOnlyInDuskAndNightwatch() {
        func same(_ a: OKLCH, _ b: OKLCH) -> Bool {
            abs(a.l - b.l) < 1e-9 && abs(a.c - b.c) < 1e-9 && abs(a.h - b.h) < 1e-6
        }
        for theme in Theme.all {
            for (dark, tokens) in [(false, theme.light), (true, theme.dark)] {
                let label = "\(theme.name) \(dark ? "dark" : "light")"
                let backdrop = theme.backdrop(dark: dark)
                #expect(backdrop.tint == tokens[.sidebarTint], "\(label)")
                if let zenith = tokens[.sky1], let horizon = tokens[.sky2] {
                    #expect(backdrop.sky.count == 8, "\(label)")
                    #expect(same(backdrop.sky.first!, zenith) && same(backdrop.sky.last!, horizon), "\(label)")
                } else {
                    #expect(backdrop.sky.isEmpty, "\(label)")
                }
                for flat in [theme.backdrop(dark: dark, increasedContrast: true), theme.backdrop(dark: dark, reducedTransparency: true)] {
                    #expect(flat.tint == tokens[.sidebarTint] && flat.sky.isEmpty, "\(label) flattened")
                }
            }
        }
    }

    @Test func skyMixesInOKLab() {
        // Dusk's indigo zenith meets its green afterglow through a grayer middle instead of turning through teal.
        let zenith = Theme.dusk.dark[.sky1]!
        let horizon = Theme.dusk.dark[.sky2]!
        let middle = zenith.mixed(with: horizon, by: 0.5)
        #expect(abs(middle.l - (zenith.l + horizon.l) / 2) < 1e-9)
        #expect(middle.c < min(zenith.c, horizon.c) * 0.7)
        #expect(abs(zenith.mixed(with: horizon, by: 0).h - zenith.h) < 1e-6)
        // A mix of two grays stays gray.
        let gray = OKLCH(l: 0.2, c: 0, h: 0).mixed(with: OKLCH(l: 0.8, c: 0, h: 0), by: 0.25)
        #expect(abs(gray.l - 0.35) < 1e-9 && gray.c == 0)
    }

    @Test func thumbnailWordsKeepToTheirSideOfTheDiagonal() {
        let cut = CGSize(width: 180, height: 100)
        let frame = CGRect(x: 42, y: 20, width: 132, height: 76)
        let sizes = (0..<60).map { CGSize(width: CGFloat(8 + $0 % 5 * 6), height: 9) }
        func diagonal(_ y: CGFloat) -> CGFloat {
            cut.width * (1 - y / cut.height)
        }
        let upper = flowAroundDiagonal(sizes[...], breaks: [3], space: 2, leading: 1.5, in: frame, cut: cut, half: .upper)
        let lower = flowAroundDiagonal(sizes[upper.count...], breaks: [3], space: 2, leading: 1.5, in: frame, cut: cut, half: .lower)
        #expect(upper.count > 3 && !lower.isEmpty)
        for (origin, size) in zip(upper, sizes) {
            #expect(origin.x + size.width <= diagonal(origin.y + size.height), "\(origin)")
            #expect(frame.contains(CGRect(origin: origin, size: size)), "\(origin)")
        }
        for (origin, size) in zip(lower, sizes[upper.count...]) {
            #expect(origin.x >= diagonal(origin.y), "\(origin)")
            #expect(frame.contains(CGRect(origin: origin, size: size)), "\(origin)")
        }
        #expect(upper[3].x == frame.minX && upper[3].y > upper[2].y)
        // Uncut, the words fill the frame in reading order.
        let whole = flowAroundDiagonal(sizes[...], space: 2, leading: 1.5, in: frame, cut: cut, half: .whole)
        #expect(whole.count > upper.count + lower.count / 2)
        #expect(zip(whole, whole.dropFirst()).allSatisfy { $0.y < $1.y || ($0.y == $1.y && $0.x < $1.x) })
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
