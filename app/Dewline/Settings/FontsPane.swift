import SwiftUI

struct FontsPane: View {
    @Bindable var store: ThemeStore
    @Environment(\.colorScheme) private var scheme
    private static let families = Faces.installed(monospaced: false)
    private static let monospaced = Faces.installed(monospaced: true)

    var body: some View {
        Form {
            Section {
                FontPreview(store: store, colors: scheme == .dark ? store.darkTheme.darkColors : store.lightTheme.lightColors)
            }
            Section {
                FacePicker(title: "Body", selection: $store.bodyFace, system: Faces.system, installed: Self.families)
                FacePicker(title: "Headings", selection: $store.headingFace, system: Faces.system, installed: Self.families)
                FacePicker(title: "Code", selection: $store.codeFace, system: ["SF Mono"], installed: Self.monospaced)
            } footer: {
                Text("Code is sized to the body font's x-height. Source mode (⌥⌘U) sets the whole page in the code font.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct FacePicker: View {
    let title: String
    @Binding var selection: String
    let system: [String]
    let installed: [String]

    var body: some View {
        Picker(title, selection: $selection) {
            Section("System") {
                ForEach(system, id: \.self) { Text($0).tag($0) }
            }
            Section("Bundled") {
                ForEach(Faces.bundled, id: \.self) { Text($0).tag($0) }
            }
            Section("Installed") {
                ForEach(installed, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

/// A heading, a paragraph and a code line set as the editor sets them, on the current theme's paper.
private struct FontPreview: View {
    let store: ThemeStore
    let colors: [Token: NSColor]

    private func color(_ token: Token) -> Color {
        Color(nsColor: colors[token]!)
    }

    var body: some View {
        let body = store.bodyFont
        let heading = store.heading(2).font
        let code = store.codeFont(size: body.pointSize * body.xHeight / store.codeFont(size: body.pointSize).xHeight)
        let excerpt = Excerpt.open
        var paragraph = AttributedString(excerpt.paragraph)
        for link in excerpt.links {
            guard let range = Range(link, in: paragraph) else { continue }
            paragraph[range].swiftUI.foregroundColor = color(.link)
            paragraph[range].swiftUI.underlineStyle = .single
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(excerpt.heading)
                .font(Font(heading))
                .lineLimit(1)
                .foregroundStyle(color(.heading))
            Text(paragraph)
                .font(Font(body))
                .lineSpacing(max(store.bodyLineHeight - (body.ascender - body.descender + body.leading), 0))
                .lineLimit(4)
                .foregroundStyle(color(.ink))
            Text(excerpt.code)
                .font(Font(code))
                .lineLimit(1)
                .foregroundStyle(color(.ink))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color(.codeBackground), in: .rect(cornerRadius: 4))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(.paper), in: .rect(cornerRadius: 6))
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
