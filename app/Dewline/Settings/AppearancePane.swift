import SwiftUI

struct AppearancePane: View {
    @Bindable var store: ThemeStore
    let library: FontLibrary
    @Environment(\.colorScheme) private var scheme
    @State private var installing = false

    var body: some View {
        let dark = scheme == .dark
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3)
        let themes: [(String?, [(String, Theme)])] = [
            (nil, Theme.all.map { ($0.name, $0) }), ("Dev pack", Theme.devPack.map { ($0.name, $0) }),
        ]
        SettingsPage {
            SettingsSection(
                title: "Theme", trailing: "\(Theme.all.count) + dev pack",
                note: "Click to use it in \(dark ? "Dark" : "Light"). Control-click for the other."
            ) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(Theme.all) { ThemeCard(theme: $0, store: store, dark: dark) }
                }
                Text("Dev pack")
                    .font(Station.section)
                    .foregroundStyle(Station.color(.ink2))
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(Theme.devPack) { ThemeCard(theme: $0, store: store, dark: dark) }
                }
            }
            SettingsSection(note: "Match system follows macOS between the light theme and the dark one.") {
                SettingsRow(label: "Mode") {
                    TextChoice(label: "Mode", selection: $store.appearance, options: [("Light", .light), ("Dark", .dark), ("Match system", .auto)])
                }
                SettingsRow(label: "Light theme") {
                    MenuField("Light theme", selection: $store.lightTheme, sections: themes)
                }
                SettingsRow(label: "Dark theme") {
                    MenuField("Dark theme", selection: $store.darkTheme, sections: themes)
                }
            }
            FontSlots(store: store, library: library, installing: $installing)
            SettingsSection(title: "The page", note: "Line width is in characters at this size.") {
                SettingsRow(label: "Text size") {
                    KeyStepper(label: "Text size", value: $store.bodySize, range: ThemeStore.bodySizes, step: 1,
                               text: { "\(Int($0)) pt" }, spoken: { "\(Int($0)) points" })
                }
                SettingsRow(label: "Line height") {
                    KeyStepper(label: "Line height", value: $store.lineHeight, range: ThemeStore.lineHeights, step: 0.02,
                               text: { $0.formatted(.number.precision(.fractionLength(2))) })
                }
                SettingsRow(label: "Line width") {
                    KeyStepper(label: "Line width", value: $store.columnWidth, range: ThemeStore.columnWidths, step: 2,
                               text: { "\(Int($0)) ch" }, spoken: { "\(Int($0)) characters" })
                }
            }
            RestoreDefaults {
                let factory = ThemeStore.factory
                store.appearance = factory.appearance
                store.lightTheme = factory.lightTheme
                store.darkTheme = factory.darkTheme
                store.bodyFace = factory.bodyFace
                store.headingFace = factory.headingFace
                store.codeFace = factory.codeFace
                store.bodySize = factory.bodySize
                store.lineHeight = factory.lineHeight
                store.columnWidth = factory.columnWidth
            }
        }
        .sheet(isPresented: $installing) {
            FontLibrarySheet(store: store, library: library)
        }
    }
}

/// A theme as a window in miniature, in the current mode, with its name under it. A 1.5 pt signal ring, 2 pt out,
/// marks the theme the current mode uses; a mono tag says when the other mode uses it.
private struct ThemeCard: View {
    let theme: Theme
    let store: ThemeStore
    let dark: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        let selected = (dark ? store.darkTheme : store.lightTheme) == theme
        let other = (dark ? store.lightTheme : store.darkTheme) == theme
        let card = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button {
            if dark { store.darkTheme = theme } else { store.lightTheme = theme }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                MiniWindow(theme: theme, dark: dark)
                    .aspectRatio(1.55, contentMode: .fit)
                    .clipShape(card)
                    .overlay(card.strokeBorder(Station.stroke, lineWidth: 1 / scale))
                    .padding(3.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12.5, style: .continuous)
                            .strokeBorder(selected ? Station.color(.accent) : .clear, lineWidth: 1.5)
                    )
                HStack(alignment: .firstTextBaseline) {
                    Text(theme.name)
                        .font(selected ? Station.labelActive : Station.label)
                        .foregroundStyle(Station.color(selected ? .ink : .ink2))
                    Spacer(minLength: 4)
                    if selected || other {
                        Text(selected ? "current" : dark ? "in light" : "in dark")
                            .font(Station.mono(11))
                            .foregroundStyle(Station.color(.ink3))
                    }
                }
                .padding(.horizontal, 3.5)
            }
        }
        .buttonStyle(BareButtonStyle(radius: 12.5))
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

/// The main window drawn small in a theme's colors: the sidebar on the chrome, a hairline, and the page with a title,
/// two lines, and one outside change underlined in the accent.
private struct MiniWindow: View {
    let theme: Theme
    let dark: Bool

    var body: some View {
        let colors = dark ? theme.darkColors : theme.lightColors
        let titleFont = Station.brand(11, weight: 600)
        Canvas { context, size in
            func color(_ token: Token) -> Color {
                Color(nsColor: colors[token] ?? colors[.ink2]!)
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color(.paper)))
            let side = CGRect(x: 0, y: 0, width: (size.width * 0.28).rounded(), height: size.height)
            context.fill(Path(side), with: .color(color(.chrome)))
            context.fill(Path(CGRect(x: side.maxX, y: 0, width: 1, height: size.height)), with: .color(color(.rule)))
            for (index, width) in [0.62, 0.44, 0.7].enumerated() {
                let bar = CGRect(x: side.minX + 8, y: 12 + CGFloat(index) * 7, width: (side.width - 16) * width, height: 2)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(color(.ink2).opacity(0.55)))
            }
            let page = CGRect(x: side.maxX + 1, y: 0, width: size.width - side.maxX - 1, height: size.height)
            let title = context.resolve(Text("Field notes").font(titleFont).foregroundStyle(color(.heading)))
            context.draw(title, at: CGPoint(x: page.minX + 10, y: page.minY + 12), anchor: .topLeading)
            for (index, width) in [0.72, 0.5].enumerated() {
                let bar = CGRect(x: page.minX + 10, y: page.minY + 32 + CGFloat(index) * 7, width: (page.width - 20) * width, height: 2)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(color(.ink2).opacity(0.5)))
            }
            let mark = CGRect(x: page.minX + 10, y: page.minY + 37, width: (page.width - 20) * 0.3, height: 1)
            context.fill(Path(mark), with: .color(color(.accent)))
        }
        .accessibilityHidden(true)
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

