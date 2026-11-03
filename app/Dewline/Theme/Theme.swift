import AppKit

/// A color as authored: OKLab lightness from 0 to 1, chroma, and hue in degrees.
struct OKLCH: Hashable, Sendable {
    let l: Double
    let c: Double
    let h: Double

    /// Linear-light sRGB components, outside 0...1 where the color lies outside sRGB.
    var linearSRGB: [Double] {
        let a = c * cos(h * .pi / 180)
        let b = c * sin(h * .pi / 180)
        let l = l + 0.3963377774 * a + 0.2158037573 * b
        let m = self.l - 0.1055613458 * a - 0.0638541728 * b
        let s = self.l - 0.0894841775 * a - 1.2914855480 * b
        let (l3, m3, s3) = (l * l * l, m * m * m, s * s * s)
        return [
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
        ]
    }

    /// The color in sRGB, or in Display P3 when it lies outside sRGB, clipped to P3.
    var color: NSColor {
        let rgb = linearSRGB
        func encoded(_ linear: [Double]) -> [Double] {
            linear.map {
                let x = min(max($0, 0), 1)
                return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            }
        }
        if rgb.allSatisfy({ (-0.0001...1.0001).contains($0) }) {
            let srgb = encoded(rgb)
            return NSColor(srgbRed: srgb[0], green: srgb[1], blue: srgb[2], alpha: 1)
        }
        let p3 = encoded([
            0.8224619687 * rgb[0] + 0.1775380313 * rgb[1],
            0.0331941989 * rgb[0] + 0.9668058011 * rgb[1],
            0.0170826307 * rgb[0] + 0.0723974407 * rgb[1] + 0.9105199286 * rgb[2],
        ])
        return NSColor(displayP3Red: p3[0], green: p3[1], blue: p3[2], alpha: 1)
    }

    /// The WCAG contrast ratio between this color and `other`.
    func contrast(with other: OKLCH) -> Double {
        func luminance(_ color: OKLCH) -> Double {
            let rgb = color.linearSRGB
            return max(0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2], 0)
        }
        let (a, b) = (luminance(self), luminance(other))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The distance to `other` in OKLab, times 100, so 1 is about the smallest difference anyone sees.
    func deltaE(_ other: OKLCH) -> Double {
        let (a0, b0) = (c * cos(h * .pi / 180), c * sin(h * .pi / 180))
        let (a1, b1) = (other.c * cos(other.h * .pi / 180), other.c * sin(other.h * .pi / 180))
        let (dl, da, db) = (l - other.l, a0 - a1, b0 - b1)
        return (dl * dl + da * da + db * db).squareRoot() * 100
    }

    func lightened(by delta: Double) -> OKLCH {
        OKLCH(l: l + delta, c: c, h: h)
    }

    /// The color `t` of the way to `other`, mixed in OKLab, so two distant hues meet through a grayer middle instead
    /// of turning through the hues between them.
    func mixed(with other: OKLCH, by t: Double) -> OKLCH {
        func lab(_ color: OKLCH) -> (Double, Double) {
            (color.c * cos(color.h * .pi / 180), color.c * sin(color.h * .pi / 180))
        }
        let (a0, b0) = lab(self)
        let (a1, b1) = lab(other)
        let (a, b) = (a0 + (a1 - a0) * t, b0 + (b1 - b0) * t)
        let hue = atan2(b, a) * 180 / .pi
        return OKLCH(l: l + (other.l - l) * t, c: (a * a + b * b).squareRoot(), h: hue < 0 ? hue + 360 : hue)
    }
}

extension OKLCH {
    /// Reads an AppKit color through extended sRGB, so a Display P3 color keeps the part outside sRGB.
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.extendedSRGB) else { return nil }
        let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { (v: CGFloat) -> Double in
            let x = abs(Double(v))
            let y = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            return v < 0 ? -y : y
        }
        let l = cbrt(0.4122214708 * linear[0] + 0.5363325363 * linear[1] + 0.0514459929 * linear[2])
        let m = cbrt(0.2119034982 * linear[0] + 0.6806995451 * linear[1] + 0.1073969566 * linear[2])
        let s = cbrt(0.0883024619 * linear[0] + 0.2817188376 * linear[1] + 0.6299787005 * linear[2])
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let hue = atan2(b, a) * 180 / .pi
        self.init(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, c: (a * a + b * b).squareRoot(), h: hue < 0 ? hue + 360 : hue)
    }
}

/// The one accent, OKLCH, for a light page and a dark one. Every accent in the app reads it through `Token.accent`, so
/// changing these two values changes the accent everywhere.
enum Brand {
    static let accent = (light: OKLCH(l: 0.508, c: 0.072, h: 178), dark: OKLCH(l: 0.769, c: 0.075, h: 176))
}

/// A theme's named colors (synthesis 2.1).
enum Token: String, CaseIterable, Sendable {
    case paper, ink, ink2, syntax, heading, accent, link, selection, sidebarTint, codeBackground, quoteRule
    /// The window's chrome around the page: sidebar, tab row, status bar, panels; and its hairlines.
    case chrome, rule
    /// Code highlighting's colors. A dev theme authors them from its editor's palette; Dewline's themes derive them
    /// (`Theme.coded`).
    case codeKeyword, codeString, codeNumber, codeType, codeFunction, codeComment, codeTag, codeInserted, codeDeleted
    /// Older chrome roles, each now one of the tokens above (`Theme.stationed`): frame, islandSide, sunken and keycap
    /// are chrome; islandEditor and raised are paper; hairline is rule; signal and glow are the accent; ink3 sits 30%
    /// of the way from ink2 to the paper.
    case frame, islandEditor, islandSide, raised, sunken, keycap, hairline, ink3, signal, glow

    static let code: [Token] = [.codeKeyword, .codeString, .codeNumber, .codeType, .codeFunction, .codeComment, .codeTag, .codeInserted, .codeDeleted]
    static let station: [Token] = [.chrome, .rule, .frame, .islandEditor, .islandSide, .raised, .sunken, .keycap, .hairline, .ink3, .signal, .glow]
    static let required = allCases.filter { !code.contains($0) && !station.contains($0) }

    /// The name in words: "code keyword", "ink 2".
    var label: String {
        rawValue.replacing(/[A-Z0-9]/) { " " + $0.output.lowercased() }
    }
}

/// One of Dewline's named themes: its tokens for a light and a dark appearance, authored in OKLCH and converted to
/// colors once, when the theme loads.
struct Theme: Identifiable, Hashable, Sendable {
    let name: String
    let summary: String
    let light: [Token: OKLCH]
    let dark: [Token: OKLCH]
    let lightColors: [Token: NSColor]
    let darkColors: [Token: NSColor]
    let increasedLightColors: [Token: NSColor]
    let increasedDarkColors: [Token: NSColor]

    var id: String { name }

    /// `table` holds one row per token: its name, then L C h for light and L C h for dark. A `-` in place of either
    /// triple leaves that side to the derivation.
    init(_ name: String, _ summary: String, _ table: String) {
        var light: [Token: OKLCH] = [:]
        var dark: [Token: OKLCH] = [:]
        for row in table.split(separator: "\n") {
            var fields = row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let token = Token(rawValue: fields.removeFirst())!
            func triple() -> OKLCH? {
                if fields.first == "-" {
                    fields.removeFirst()
                    return nil
                }
                let values = fields.prefix(3).map { Double($0)! }
                fields.removeFirst(3)
                return OKLCH(l: values[0], c: values[1], h: values[2])
            }
            light[token] = triple()
            dark[token] = triple()
        }
        let authored = (light: light, dark: dark)
        light = Self.stationed(Self.coded(light), increased: false)
        dark = Self.stationed(Self.coded(dark), increased: false)
        self.name = name
        self.summary = summary
        self.light = light
        self.dark = dark
        lightColors = light.mapValues(\.color)
        darkColors = dark.mapValues(\.color)
        // A dark-only port carries its dark block in the light slot too, so contrast rises away from the paper.
        increasedLightColors = Self.stationed(Self.coded(Self.increased(authored.light, dark: light[.paper]!.l < 0.5)), increased: true).mapValues(\.color)
        increasedDarkColors = Self.stationed(Self.coded(Self.increased(authored.dark, dark: dark[.paper]!.l < 0.5)), increased: true).mapValues(\.color)
    }

    /// `tokens` with the chrome's roles, stepped off the paper in its own hue so every theme has them: chrome a step
    /// darker than the paper in light and lighter in dark, the rule further, ink3 30% of the way from ink2 to the paper.
    /// The older roles alias these. Under Increase Contrast the rule takes ink3. A role the theme authors stays.
    static func stationed(_ authored: [Token: OKLCH], increased: Bool) -> [Token: OKLCH] {
        let paper = authored[.paper]!
        let dark = paper.l < 0.5
        let hue = authored[.sidebarTint]!.h
        let chroma = min(paper.c * 1.6, 0.03)
        func step(_ delta: Double) -> OKLCH {
            OKLCH(l: min(max(paper.l + (dark ? delta : -delta), 0), 1), c: chroma, h: hue)
        }
        let chrome = authored[.chrome] ?? step(dark ? 0.03 : 0.02)
        let ink3 = authored[.ink3] ?? authored[.ink2]!.mixed(with: paper, by: 0.3)
        let rule = authored[.rule] ?? step(dark ? 0.13 : 0.085)
        let accent = authored[.accent]!
        let derived: [Token: OKLCH] = [
            .chrome: chrome, .rule: rule, .ink3: ink3,
            .frame: chrome, .islandSide: chrome, .sunken: chrome, .keycap: chrome,
            .islandEditor: paper, .raised: paper, .hairline: rule,
            .signal: accent, .glow: accent,
        ]
        var tokens = authored.merging(derived) { authored, _ in authored }
        if increased { (tokens[.rule], tokens[.hairline]) = (ink3, ink3) }
        return tokens
    }

    /// `tokens` with code highlighting's colors: keywords in the accent's hue, the rest at hues turned from the link's,
    /// all at the link's lightness, which reads on the paper; comments in ink2, tags and keys in the heading's color,
    /// insertions green and deletions red. A code color the theme authors, as a dev theme does from its editor's
    /// palette, stays.
    static func coded(_ authored: [Token: OKLCH]) -> [Token: OKLCH] {
        let link = authored[.link]!
        let accent = authored[.accent]!
        func turned(_ hue: Double) -> OKLCH {
            OKLCH(l: link.l, c: min(max(link.c, 0.08), 0.14), h: (hue + 360).truncatingRemainder(dividingBy: 360))
        }
        let derived: [Token: OKLCH] = [
            .codeKeyword: OKLCH(l: link.l, c: min(max(accent.c, 0.08), 0.16), h: accent.h),
            .codeString: turned(link.h + 240),
            .codeNumber: turned(link.h + 60),
            .codeType: turned(link.h + 150),
            .codeFunction: turned(link.h - 35),
            .codeComment: authored[.ink2]!,
            .codeTag: authored[.heading]!,
            .codeInserted: turned(150),
            .codeDeleted: turned(25),
        ]
        return authored.merging(derived) { authored, _ in authored }
    }

    /// `tokens` under Increase Contrast (synthesis 2.1): ink at L 0.15 or 0.97, ink2 at 7:1 on paper and syntax with it,
    /// link and accent 0.06 further from the paper.
    static func increased(_ tokens: [Token: OKLCH], dark: Bool) -> [Token: OKLCH] {
        let step = dark ? 0.01 : -0.01
        var tokens = tokens
        let ink = tokens[.ink]!
        tokens[.ink] = OKLCH(l: dark ? 0.97 : 0.15, c: ink.c, h: ink.h)
        var ink2 = tokens[.ink2]!
        while ink2.contrast(with: tokens[.paper]!) < 7 {
            ink2 = ink2.lightened(by: step)
        }
        tokens[.ink2] = ink2
        tokens[.syntax] = ink2
        tokens[.link] = tokens[.link]!.lightened(by: 6 * step)
        tokens[.accent] = tokens[.accent]!.lightened(by: 6 * step)
        return tokens
    }

    static func == (lhs: Theme, rhs: Theme) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    static func named(_ name: String) -> Theme? {
        (all + devPack).first { $0.name == name }
    }

    static let all = [tidewater, aurora, dawnline, dusk, nightwatch, carbon]

    /// Ports of editor themes, code colors included, from each original palette. Nord has no light version, so its
    /// dark one fills both slots.
    static let devPack = [solarized, gruvbox, nord, tokyoNight]

    var isDarkOnly: Bool { light[.paper]!.l < 0.5 }

    /// The defaults' neutral palette, the same in both: near-white paper and near-black ink by day, the reverse at
    /// night, all at chroma 0.006 or less, with the brand's accent as the only color.
    private static let neutral = """
        paper           0.985 0.002 180   0.175 0.004 180
        chrome          0.965 0.002 180   0.205 0.004 180
        ink             0.22  0.005 180   0.93  0.004 180
        ink2            0.50  0.005 180   0.70  0.005 180
        rule            0.90  0.003 180   0.30  0.004 180
        codeBackground  0.955 0.002 180   0.215 0.004 180
        heading         0.22  0.005 180   0.93  0.004 180
        link            0.22  0.005 180   0.93  0.004 180
        selection       0.878 0.002 180   0.281 0.004 180
        syntax          0.62  0.004 180   0.52  0.004 180
        sidebarTint     0.965 0.002 180   0.205 0.004 180
        quoteRule       0.80  0.003 180   0.40  0.004 180
        accent          \(Brand.accent.light.l) \(Brand.accent.light.c) \(Brand.accent.light.h)   \(Brand.accent.dark.l) \(Brand.accent.dark.c) \(Brand.accent.dark.h)
        """

    static let tidewater = Theme("Tidewater", "Near-white paper, near-black ink, one green accent.", neutral)

    static let aurora = Theme("Aurora", "Sage paper by day; polar-night navy with green links after dark.", """
        paper           0.988 0.008 160   0.19  0.02  250
        ink             0.25  0.02  165   0.92  0.015 160
        ink2            0.47  0.025 165   0.77  0.02  165
        syntax          0.655 0.02  165   0.50  0.02  220
        heading         0.34  0.07  158   0.88  0.09  155
        accent          0.55  0.14  152   0.80  0.15  155
        link            0.50  0.13  152   0.84  0.13  152
        selection       0.89  0.05  235   0.36  0.06  235
        sidebarTint     0.93  0.035 155   0.25  0.035 230
        codeBackground  0.96  0.015 160   0.23  0.025 240
        quoteRule       0.66  0.12  152   0.66  0.13  155
        frame           -                 0.247 0.028 176
        islandSide      -                 0.216 0.022 175
        """)

    static let dawnline = Theme("Dawnline", "A blush of dawn in the paper, ultramarine ink and accents; warm ink on indigo at night.", """
        paper           0.985 0.008 20    0.21  0.022 268
        ink             0.24  0.025 265   0.92  0.01  30
        ink2            0.48  0.03  265   0.77  0.015 30
        syntax          0.655 0.02  20    0.505 0.02  268
        heading         0.32  0.08  262   0.90  0.04  40
        accent          0.52  0.17  258   0.76  0.10  252
        link            0.50  0.17  258   0.85  0.08  250
        selection       0.89  0.04  258   0.37  0.06  262
        sidebarTint     0.94  0.02  20    0.27  0.035 268
        codeBackground  0.965 0.008 255   0.25  0.022 268
        quoteRule       0.70  0.08  258   0.64  0.09  252
        frame           -                 0.267 0.025 314
        islandSide      -                 0.236 0.02  314
        """)

    static let dusk = Theme("Dusk", "Blue hour: indigo above a green afterglow, mint accents, periwinkle links.", """
        paper           0.978 0.010 268   0.21  0.03  272
        ink             0.25  0.03  270   0.92  0.012 262
        ink2            0.47  0.03  268   0.77  0.02  265
        syntax          0.65  0.02  266   0.505 0.03  270
        heading         0.32  0.10  270   0.88  0.07  160
        accent          0.52  0.12  158   0.80  0.12  158
        link            0.48  0.15  264   0.84  0.09  262
        selection       0.89  0.05  264   0.37  0.07  268
        sidebarTint     0.935 0.025 270   0.25  0.04  272
        codeBackground  0.96  0.012 268   0.245 0.03  272
        quoteRule       0.66  0.11  160   0.66  0.11  160
        frame           -                 0.267 0.051 289
        islandSide      -                 0.236 0.043 288
        """)

    static let nightwatch = Theme("Nightwatch", "Near-black paper, light gray ink, one green accent.", neutral)

    static let carbon = Theme("Carbon", "Onionskin and carbon ink, the manuscript.", """
        paper           0.97  0.003 250   0.185 0.003 260
        ink             0.21  0.004 260   0.92  0.003 250
        ink2            0.45  0.004 260   0.78  0.004 255
        syntax          0.645 0.004 260   0.495 0.004 260
        heading         0.21  0.004 260   0.92  0.003 250
        accent          0.46  0.17  258   0.80  0.10  258
        link            0.46  0.17  258   0.84  0.10  258
        selection       0.88  0.05  258   0.34  0.06  258
        sidebarTint     0.94  0.004 250   0.215 0.003 260
        codeBackground  0.94  0.004 250   0.225 0.003 260
        quoteRule       0.62  0.10  258   0.60  0.09  258
        """)

    static let solarized = Theme("Solarized", "Ethan Schoonover's sixteen colors: base3 paper by day, base03 at night.", """
        paper           0.974 0.026 90    0.267 0.049 220
        ink             0.523 0.028 219   0.654 0.02  205
        ink2            0.568 0.029 222   0.568 0.029 222
        syntax          0.698 0.016 197   0.523 0.028 219
        heading         0.309 0.052 220   0.698 0.016 197
        accent          0.615 0.139 245   0.615 0.139 245
        link            0.615 0.139 245   0.615 0.139 245
        selection       0.931 0.026 92    0.309 0.052 220
        sidebarTint     0.931 0.026 92    0.309 0.052 220
        codeBackground  0.931 0.026 92    0.309 0.052 220
        quoteRule       0.698 0.016 197   0.523 0.028 219
        codeKeyword     0.644 0.151 119   0.644 0.151 119
        codeString      0.644 0.102 187   0.644 0.102 187
        codeType        0.654 0.134 86    0.654 0.134 86
        codeComment     0.698 0.016 197   0.523 0.028 219
        """)

    static let gruvbox = Theme("Gruvbox", "Retro groove: warm parchment by day, charcoal and cream at night.", """
        paper           0.956 0.055 96    0.277 0     0
        ink             0.344 0.007 49    0.894 0.057 89
        ink2            0.55  0.023 63    0.69  0.035 76
        syntax          0.619 0.029 67    0.619 0.029 67
        heading         0.513 0.162 39    0.731 0.182 52
        accent          0.471 0.082 216   0.693 0.042 170
        link            0.471 0.082 216   0.693 0.042 170
        selection       0.825 0.051 85    0.411 0.012 52
        sidebarTint     0.894 0.057 89    0.344 0.007 49
        codeBackground  0.922 0.055 93    0.311 0.003 49
        quoteRule       0.534 0.082 155   0.756 0.108 138
        codeKeyword     0.437 0.179 28    0.66  0.218 30
        codeString      0.546 0.112 106   0.765 0.158 111
        codeType        0.618 0.128 71    0.832 0.159 83
        codeComment     0.619 0.029 67    0.619 0.029 67
        """)

    static let nord = Theme("Nord", "Arctic: Polar Night paper, Snow Storm ink, Frost accents. Dark only.", """
        paper           0.324 0.023 264   0.324 0.023 264
        ink             0.899 0.016 263   0.899 0.016 263
        ink2            0.739 0.022 262   0.739 0.022 262
        syntax          0.537 0.044 264   0.537 0.044 264
        heading         0.775 0.062 217   0.775 0.062 217
        accent          0.775 0.062 217   0.775 0.062 217
        link            0.697 0.059 249   0.697 0.059 249
        selection       0.416 0.032 264   0.416 0.032 264
        sidebarTint     0.379 0.029 266   0.379 0.029 266
        codeBackground  0.379 0.029 266   0.379 0.029 266
        quoteRule       0.594 0.077 254   0.594 0.077 254
        codeKeyword     0.697 0.059 249   0.697 0.059 249
        codeString      0.768 0.075 131   0.768 0.075 131
        codeType        0.763 0.048 194   0.763 0.048 194
        codeComment     0.537 0.044 264   0.537 0.044 264
        """)

    static let tokyoNight = Theme("Tokyo Night", "Downtown Tokyo after dark; Tokyo Night Day for the light slot.", """
        paper           0.913 0.007 277   0.226 0.021 280
        ink             0.512 0.156 264   0.846 0.061 275
        ink2            0.565 0.098 271   0.767 0.054 275
        syntax          0.649 0.062 276   0.496 0.068 274
        heading         0.6   0.18  258   0.719 0.132 264
        accent          0.514 0.103 231   0.82  0.105 236
        link            0.573 0.105 174   0.822 0.1   182
        selection       0.809 0.05  274   0.332 0.064 268
        sidebarTint     0.873 0.02  270   0.204 0.016 285
        codeBackground  0.873 0.02  270   0.204 0.016 285
        quoteRule       0.732 0.045 278   0.409 0.055 274
        codeKeyword     0.604 0.225 299   0.751 0.134 299
        codeString      0.525 0.093 130   0.795 0.139 130
        codeType        0.553 0.091 213   0.754 0.124 213
        codeComment     0.649 0.062 276   0.496 0.068 274
        """)
}
