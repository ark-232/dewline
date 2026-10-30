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

/// A theme's named colors (synthesis 2.1).
enum Token: String, CaseIterable, Sendable {
    case paper, ink, ink2, syntax, heading, accent, link, selection, sidebarTint, codeBackground, quoteRule
    /// The sky behind the glass, zenith and horizon; only Dusk and Nightwatch have one.
    case sky1, sky2
    /// Code highlighting's colors, derived from the theme's (`Theme.coded`).
    case codeKeyword, codeString, codeNumber, codeType, codeFunction, codeComment, codeTag, codeInserted, codeDeleted

    static let required = allCases.filter { $0 != .sky1 && $0 != .sky2 }
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

    var hasSky: Bool { light[.sky1] != nil }

    /// `table` holds one row per token: its name, then L C h for light and L C h for dark.
    init(_ name: String, _ summary: String, _ table: String) {
        var light: [Token: OKLCH] = [:]
        var dark: [Token: OKLCH] = [:]
        for row in table.split(separator: "\n") {
            let fields = row.split(separator: " ", omittingEmptySubsequences: true)
            let token = Token(rawValue: String(fields[0]))!
            let values = fields.dropFirst().map { Double($0)! }
            light[token] = OKLCH(l: values[0], c: values[1], h: values[2])
            dark[token] = OKLCH(l: values[3], c: values[4], h: values[5])
        }
        light = Self.coded(light)
        dark = Self.coded(dark)
        self.name = name
        self.summary = summary
        self.light = light
        self.dark = dark
        lightColors = light.mapValues(\.color)
        darkColors = dark.mapValues(\.color)
        increasedLightColors = Self.coded(Self.increased(light, dark: false)).mapValues(\.color)
        increasedDarkColors = Self.coded(Self.increased(dark, dark: true)).mapValues(\.color)
    }

    /// `tokens` with code highlighting's colors: keywords in the accent's hue, the rest at hues turned from the link's,
    /// all at the link's lightness, which reads on the paper; comments in ink2, tags and keys in the heading's color,
    /// insertions green and deletions red.
    static func coded(_ tokens: [Token: OKLCH]) -> [Token: OKLCH] {
        var tokens = tokens
        let link = tokens[.link]!
        let accent = tokens[.accent]!
        func turned(_ hue: Double) -> OKLCH {
            OKLCH(l: link.l, c: min(max(link.c, 0.08), 0.14), h: (hue + 360).truncatingRemainder(dividingBy: 360))
        }
        tokens[.codeKeyword] = OKLCH(l: link.l, c: min(max(accent.c, 0.08), 0.16), h: accent.h)
        tokens[.codeString] = turned(link.h + 240)
        tokens[.codeNumber] = turned(link.h + 60)
        tokens[.codeType] = turned(link.h + 150)
        tokens[.codeFunction] = turned(link.h - 35)
        tokens[.codeComment] = tokens[.ink2]!
        tokens[.codeTag] = tokens[.heading]!
        tokens[.codeInserted] = turned(150)
        tokens[.codeDeleted] = turned(25)
        return tokens
    }

    /// `tokens` under Increase Contrast (synthesis 2.1): ink at L 0.15 or 0.97, ink2 at 7:1 on paper and syntax with it,
    /// link and accent 0.06 further from the paper, and no sky.
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
        tokens[.sky1] = nil
        tokens[.sky2] = nil
        return tokens
    }

    /// What shows through the sidebar and toolbar glass (synthesis 2.4): the sidebar tint, and the sky from zenith to
    /// horizon in eight steps mixed in OKLab. Themes without a sky, Increase Contrast and Reduce Transparency leave the
    /// tint flat.
    func backdrop(dark: Bool, increasedContrast: Bool = false, reducedTransparency: Bool = false) -> (tint: OKLCH, sky: [OKLCH]) {
        let tokens = dark ? self.dark : light
        let tint = tokens[.sidebarTint]!
        guard let zenith = tokens[.sky1], let horizon = tokens[.sky2], !increasedContrast, !reducedTransparency else {
            return (tint, [])
        }
        return (tint, (0...7).map { zenith.mixed(with: horizon, by: Double($0) / 7) })
    }

    static func == (lhs: Theme, rhs: Theme) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    static func named(_ name: String) -> Theme? {
        all.first { $0.name == name }
    }

    static let all = [tidewater, aurora, dawnline, dusk, nightwatch, carbon]

    static let tidewater = Theme("Tidewater", "Cool white paper, cobalt for what you can act on, deep-cobalt headings.", """
        paper           0.99  0.006 250   0.20  0.02  262
        ink             0.24  0.02  262   0.92  0.01  262
        ink2            0.47  0.02  262   0.77  0.02  262
        syntax          0.66  0.02  262   0.50  0.02  262
        heading         0.30  0.09  266   0.88  0.06  262
        accent          0.50  0.20  266   0.70  0.15  262
        link            0.48  0.19  266   0.84  0.10  258
        selection       0.88  0.06  262   0.36  0.08  264
        sidebarTint     0.93  0.03  262   0.26  0.04  264
        codeBackground  0.965 0.01  255   0.24  0.02  262
        quoteRule       0.62  0.14  266   0.62  0.13  264
        """)

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
        sky1            0.80  0.06  270   0.17  0.06  272
        sky2            0.93  0.04  160   0.34  0.06  165
        """)

    static let nightwatch = Theme("Nightwatch", "Dark-first, for the radar room: deep navy, sky-blue accents; overcast steel by day.", """
        paper           0.975 0.01  245   0.17  0.025 255
        ink             0.22  0.03  255   0.90  0.02  230
        ink2            0.46  0.03  252   0.77  0.03  235
        syntax          0.65  0.025 250   0.485 0.035 245
        heading         0.27  0.06  255   0.95  0.03  235
        accent          0.47  0.16  255   0.76  0.12  240
        link            0.45  0.15  255   0.84  0.095 238
        selection       0.87  0.05  250   0.34  0.08  250
        sidebarTint     0.91  0.03  250   0.22  0.04  255
        codeBackground  0.945 0.015 250   0.21  0.03  255
        quoteRule       0.55  0.12  255   0.60  0.12  245
        sky1            0.86  0.03  250   0.12  0.035 265
        sky2            0.95  0.012 245   0.23  0.05  250
        """)

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
}
