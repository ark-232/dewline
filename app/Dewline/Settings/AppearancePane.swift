import SwiftUI

struct AppearancePane: View {
    @Bindable var store: ThemeStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
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
                        ThemeCard(theme: theme, store: store, dark: scheme == .dark)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            } footer: {
                Text("Click a theme to use it in \(scheme == .dark ? "Dark" : "Light"). Control-click to pick the slot.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A theme's thumbnail, light above the diagonal and dark below, with a ring when the current slot holds it.
private struct ThemeCard: View {
    let theme: Theme
    @Bindable var store: ThemeStore
    let dark: Bool

    var body: some View {
        let selected = (dark ? store.darkTheme : store.lightTheme) == theme
        Button {
            if dark { store.darkTheme = theme } else { store.lightTheme = theme }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    PagePreview(colors: theme.lightColors, store: store)
                    PagePreview(colors: theme.darkColors, store: store)
                        .clipShape(LowerTriangle())
                }
                .frame(height: 92)
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
    @Bindable var store: ThemeStore

    var body: some View {
        let selected = store.appearance == mode
        Button {
            store.appearance = mode
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if mode != .dark {
                        PagePreview(colors: store.lightTheme.lightColors, store: store, lines: true)
                    }
                    if mode != .light {
                        PagePreview(colors: store.darkTheme.darkColors, store: store, lines: true)
                            .clipShape(mode == .auto ? AnyShape(LowerTriangle()) : AnyShape(Rectangle()))
                    }
                }
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

/// The half of a rectangle below the diagonal from its bottom-left corner to its top-right one.
private struct LowerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// A small window in one theme's colors: the sidebar tint, and a page set in the store's faces, or drawn as bars
/// when `lines` is set.
struct PagePreview: View {
    let colors: [Token: NSColor]
    let store: ThemeStore
    var lines = false

    private func color(_ token: Token) -> Color {
        Color(nsColor: colors[token]!)
    }

    private var paragraph: AttributedString {
        var picked = AttributedString("on 2 December")
        picked.swiftUI.backgroundColor = color(.selection)
        var link = AttributedString("release checklist")
        link.swiftUI.foregroundColor = color(.link)
        link.swiftUI.underlineStyle = .single
        return AttributedString("Ship the notarized build to the first forty testers. Public beta opens ") + picked
            + AttributedString(", after the dry run. Steps in the ") + link + AttributedString(".")
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: lines ? 3 : 5) {
                Capsule().fill(color(.accent)).frame(width: lines ? 9 : 16, height: lines ? 2.5 : 4)
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(color(.ink2).opacity(0.4)).frame(width: lines ? 8 : 14, height: lines ? 2.5 : 4)
                }
            }
            .padding(lines ? 4 : 7)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(color(.sidebarTint))
            Group {
                if lines {
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(color(.heading)).frame(width: 22, height: 3)
                        Capsule().fill(color(.ink).opacity(0.75)).frame(width: 34, height: 2)
                        Capsule().fill(color(.ink).opacity(0.75)).frame(width: 30, height: 2)
                        Capsule().fill(color(.link)).frame(width: 14, height: 2)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dewline 1.0 launch plan")
                            .font(Font(Faces.font(store.headingFace, size: 10.5, weight: .semibold)))
                            .foregroundStyle(color(.heading))
                        Text(paragraph)
                            .font(Font(Faces.font(store.bodyFace, size: 7.5)))
                            .foregroundStyle(color(.ink))
                            .lineSpacing(1)
                        Text("xcodebuild -scheme Dewline")
                            .font(Font(Faces.font(store.codeFace, size: 6.5)))
                            .foregroundStyle(color(.ink))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1.5)
                            .background(color(.codeBackground), in: .rect(cornerRadius: 2))
                    }
                }
            }
            .padding(lines ? 5 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color(.paper))
        }
    }
}
