import SwiftUI

struct AppearancePane: View {
    @Bindable var store: ThemeStore
    @Environment(\.colorScheme) private var scheme
    @AppStorage("DewlineMotion") private var motion = Motion.calm

    var body: some View {
        let excerpt = Excerpt.open
        Form {
            Section {
                LabeledContent("Appearance") {
                    HStack(spacing: 16) {
                        ForEach(ThemeStore.Appearance.allCases) { mode in
                            ModeTile(mode: mode, store: store)
                        }
                    }
                }
            } footer: {
                Text("Auto follows macOS. Every theme has a light and a dark version.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker(selection: $store.lightTheme) {
                    ForEach(Theme.all) { Text($0.name).tag($0) }
                } label: {
                    Label("In Light", systemImage: "sun.max")
                }
                Picker(selection: $store.darkTheme) {
                    ForEach(Theme.all) { Text($0.name).tag($0) }
                } label: {
                    Label("In Dark", systemImage: "moon")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    ForEach(Theme.all) { theme in
                        ThemeCard(theme: theme, store: store, excerpt: excerpt, dark: scheme == .dark)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text("Click a theme to use it in \(scheme == .dark ? "Dark" : "Light"). Control-click to pick the slot.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Motion", selection: $motion) {
                    Text("Off").tag(Motion.off)
                    Text("Calm").tag(Motion.calm)
                    Text("Lively").tag(Motion.lively)
                }
            } footer: {
                Text("Calm streaks the caret to where a jump such as Find Next or Go to Line lands; Lively does it for clicks and long moves too. With Reduce Motion on, Dewline uses Off.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A theme's thumbnail, light above the diagonal and dark below, with a ring when the current slot holds it.
private struct ThemeCard: View {
    let theme: Theme
    let store: ThemeStore
    let excerpt: Excerpt
    let dark: Bool

    var body: some View {
        let selected = (dark ? store.darkTheme : store.lightTheme) == theme
        Button {
            if dark { store.darkTheme = theme } else { store.lightTheme = theme }
        } label: {
            VStack(spacing: 6) {
                Thumbnail(light: theme, dark: theme, store: store, excerpt: excerpt)
                .frame(height: 100)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                HStack(spacing: 4) {
                    Text(theme.name)
                    if store.lightTheme == theme {
                        Image(systemName: "sun.max.fill").help("Used in Light")
                    }
                    if store.darkTheme == theme {
                        Image(systemName: "moon.fill").help("Used in Dark")
                    }
                }
                .font(.callout)
                .imageScale(.small)
                .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Use in Light") { store.lightTheme = theme }
            Button("Use in Dark") { store.darkTheme = theme }
        }
        .help(theme.summary)
        .accessibilityLabel(theme.name)
        .accessibilityHint(theme.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Light, Dark or Auto: a swatch of the slot's theme over the mode's name.
private struct ModeTile: View {
    let mode: ThemeStore.Appearance
    let store: ThemeStore

    var body: some View {
        let selected = store.appearance == mode
        Button {
            store.appearance = mode
        } label: {
            VStack(spacing: 5) {
                Thumbnail(light: mode == .dark ? nil : store.lightTheme, dark: mode == .light ? nil : store.darkTheme, store: store, lines: true)
                .frame(width: 68, height: 44)
                .clipShape(.rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(mode.rawValue.capitalized)
                    .font(.callout)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Which part of a thumbnail cut by its diagonal, from the bottom-left corner to the top-right one, a theme fills.
enum ThumbnailHalf {
    case whole, upper, lower
}

/// Origins for the first of `sizes` that fit in `frame`, set in lines from its top with `space` between words and
/// `leading` between lines; a word in `breaks` starts a new line. Words keep to their side of the diagonal of `cut`:
/// `.upper` words end before it, and since its lines only shorten going down, the first word that cannot start a line
/// ends the flow; `.lower` words start after it, and a line shorter than 40% of the frame, or too short for the next
/// word, stays empty.
func flowAroundDiagonal(
    _ sizes: ArraySlice<CGSize>, breaks: Set<Int> = [], space: CGFloat, leading: CGFloat, in frame: CGRect, cut: CGSize, half: ThumbnailHalf
) -> [CGPoint] {
    // Where the diagonal crosses the line `y` points from the top.
    func diagonal(_ y: CGFloat) -> CGFloat {
        cut.width * (1 - y / cut.height)
    }
    var origins: [CGPoint] = []
    var index = sizes.startIndex
    var top = frame.minY
    while index < sizes.endIndex, top + sizes[index].height <= frame.maxY {
        let height = sizes[index].height
        var x = half == .lower ? max(frame.minX, diagonal(top) + space) : frame.minX
        let limit = half == .upper ? min(frame.maxX, diagonal(top + height) - space) : frame.maxX
        let first = index
        while index < sizes.endIndex, index == first || !breaks.contains(index), x + sizes[index].width <= limit,
            half != .lower || limit - x >= frame.width * 0.4 || index > first
        {
            origins.append(CGPoint(x: x, y: top))
            x += sizes[index].width + space
            index += 1
        }
        if index == first, half != .lower { break }
        top += height + leading
    }
    return origins
}

/// A theme in miniature (synthesis 2.8): its tint behind a glass sidebar and the toolbar band, with the sky for Dusk
/// and Nightwatch, and its paper with the excerpt. With both themes given, `light` fills the corner above the diagonal
/// and `dark` the corner below it, and the words flow around the diagonal so none is cut by it: the light half sets
/// the opening, the dark half the rest. With `lines`, bars stand in for the words.
struct Thumbnail: View {
    var light: Theme?
    var dark: Theme?
    let store: ThemeStore
    var excerpt = Excerpt()
    var lines = false

    private struct Word {
        let text: String
        let token: Token
        var selected = false
    }

    /// The heading's words, then the paragraph's, or bars for a heading and four lines.
    private var words: [Word] {
        if lines {
            return [Word(text: "", token: .heading)] + [Token.ink, .ink, .link, .ink].map { Word(text: "", token: $0) }
        }
        let paragraph = excerpt.paragraph
        let body = paragraph.split(separator: " ").prefix(60).map { word in
            let range = NSRange(word.startIndex..<word.endIndex, in: paragraph)
            let link = excerpt.links.contains { NSIntersectionRange($0, range).length > 0 }
            return Word(text: String(word), token: link ? .link : .ink, selected: NSIntersectionRange(excerpt.selection, range).length > 0)
        }
        return excerpt.heading.split(separator: " ").map { Word(text: String($0), token: .heading) } + body
    }

    var body: some View {
        let words = words
        let headingFont = Font(Faces.font(store.headingFace, size: 10, weight: .semibold))
        let bodyFont = Font(Faces.font(store.bodyFace, size: 7))
        let halves: [(Theme, Bool, ThumbnailHalf)] = switch (light, dark) {
        case let (light?, dark?): [(light, false, .upper), (dark, true, .lower)]
        case let (light?, nil): [(light, false, .whole)]
        case let (nil, dark?): [(dark, true, .whole)]
        case (nil, nil): []
        }
        Canvas { context, size in
            let band = (size.height * 0.15).rounded()
            let sidebar = CGRect(x: 0, y: 0, width: (size.width * 0.2).rounded(), height: size.height)
            let page = CGRect(x: sidebar.maxX, y: band, width: size.width - sidebar.maxX, height: size.height - band)
            let inset: CGFloat = lines ? 4 : 6
            let column = page.insetBy(dx: inset, dy: inset - 1)
            let space: CGFloat = lines ? 3 : 2
            func text(_ word: Word, _ color: Color) -> Text {
                let text = Text(word.text).font(word.token == .heading ? headingFont : bodyFont).foregroundStyle(color)
                return word.token == .link ? text.underline() : text
            }
            let bars: [CGFloat] = [0.4, 0.62, 0.5, 0.28, 0.56]
            let sizes = words.indices.map { index in
                lines
                    ? CGSize(width: column.width * bars[index], height: index == 0 ? 3 : 2)
                    : context.resolve(text(words[index], .black)).measure(in: size)
            }
            let breaks: Set<Int> = lines ? Set(words.indices) : [words.firstIndex { $0.token != .heading } ?? words.count]
            var next = 0
            for (theme, dark, half) in halves {
                let colors = dark ? theme.darkColors : theme.lightColors
                func color(_ token: Token) -> Color {
                    Color(nsColor: colors[token]!)
                }
                var context = context
                if half != .whole {
                    context.clip(to: Path { path in
                        path.move(to: CGPoint(x: 0, y: half == .upper ? 0 : size.height))
                        path.addLine(to: CGPoint(x: size.width, y: 0))
                        path.addLine(to: CGPoint(x: half == .upper ? 0 : size.width, y: size.height))
                        path.closeSubpath()
                    })
                }
                // The backdrop: the tint, under the sky that reaches its horizon at the foot of the toolbar band.
                let backdrop = theme.backdrop(dark: dark)
                let tint = Color(nsColor: backdrop.tint.color)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tint))
                if !backdrop.sky.isEmpty {
                    let height = band * 1.5
                    let stops = backdrop.sky.enumerated().map { index, stop in
                        Gradient.Stop(color: Color(nsColor: stop.color), location: CGFloat(index) / CGFloat(backdrop.sky.count - 1) / 1.5)
                    }
                    context.fill(
                        Path(CGRect(x: 0, y: 0, width: size.width, height: height)),
                        with: .linearGradient(Gradient(stops: stops + [Gradient.Stop(color: tint, location: 1)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: height))
                    )
                }
                // The sidebar's glass over the backdrop: an accent row and three rows of second ink.
                context.fill(Path(sidebar), with: .color(.white.opacity(dark ? 0.06 : 0.3)))
                let row = sidebar.width - (lines ? 6 : 10)
                for (index, (width, token)) in [(0.5, Token.accent), (0.8, .ink2), (0.65, .ink2), (0.75, .ink2)].enumerated() {
                    let bar = CGRect(x: lines ? 3 : 5, y: band + (lines ? 3 : 4) + CGFloat(index) * (lines ? 4 : 6), width: row * width, height: lines ? 2 : 2.5)
                    context.fill(Path(roundedRect: bar, cornerRadius: bar.height / 2), with: .color(color(token).opacity(token == .accent ? 1 : 0.45)))
                }
                context.fill(Path(page), with: .color(color(.paper)))
                let origins = flowAroundDiagonal(
                    sizes[next...], breaks: breaks, space: space, leading: lines ? 3 : 1.5, in: column, cut: size, half: half
                )
                for (index, origin) in zip(next..., origins) {
                    let frame = CGRect(origin: origin, size: sizes[index])
                    if lines {
                        let ink = words[index].token == .ink ? color(.ink).opacity(0.75) : color(words[index].token)
                        context.fill(Path(roundedRect: frame, cornerRadius: frame.height / 2), with: .color(ink))
                        continue
                    }
                    if words[index].selected {
                        context.fill(Path(frame.insetBy(dx: -space / 2, dy: 0)), with: .color(color(.selection)))
                    }
                    context.draw(context.resolve(text(words[index], color(words[index].token))), at: origin, anchor: .topLeading)
                }
                next += origins.count
            }
        }
    }
}
