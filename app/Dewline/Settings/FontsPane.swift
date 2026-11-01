import SwiftUI
import UniformTypeIdentifiers

/// The body, heading and code faces and the pairings, as sections of Settings > Appearance. Install Fonts opens the
/// catalog and the added fonts in a sheet.
struct FontSlots: View {
    @Bindable var store: ThemeStore
    let library: FontLibrary
    @Binding var installing: Bool
    @State private var applying: String?
    @State private var pairingFailure: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = scheme == .dark ? store.darkTheme.darkColors : store.lightTheme.lightColors
        let mac = library.macFamilies
        let ours = library.installed.union(library.addedFamilies)
        let catalogMono = library.installed.filter { FontCatalog.family($0)?.role == .mono }
        let addedMono = Set(library.added.filter(\.monospaced).map(\.family))
        let text = [
            ("System", Faces.system), ("Bundled", Faces.bundled), ("Catalog", library.installed.sorted()),
            ("Added", library.addedFamilies), ("This Mac", mac.all.filter { !ours.contains($0) }),
        ]
        let faces = { (sections: [(String, [String])]) -> [(String?, [(String, String)])] in
            sections.filter { !$0.1.isEmpty }.map { ($0.0, $0.1.map { ($0, $0) }) }
        }
        let code = [
            ("System", ["SF Mono"]), ("Bundled", Faces.bundled), ("Catalog", catalogMono.sorted()),
            ("Added", addedMono.sorted()), ("This Mac", mac.monospaced.filter { !ours.contains($0) }),
        ]
        SettingsSection(title: "Faces", note: "A pairing sets the body, heading and code fonts at once, downloading any it needs from the catalog.") {
            SettingsRow(label: "Typeface pairing") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Pairing.all) { pairing in
                        PairingRow(pairing: pairing, store: store, busy: applying == pairing.name) {
                            apply(pairing)
                        }
                        .disabled(applying != nil)
                    }
                    if let pairingFailure {
                        Text(pairingFailure)
                            .font(Station.small)
                            .foregroundStyle(Station.color(.ink))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SettingsRow(label: "Body") {
                MenuField("Body font", selection: $store.bodyFace, sections: faces(text))
            }
            SettingsRow(label: "Headings") {
                MenuField("Heading font", selection: $store.headingFace, sections: faces(text))
            }
            SettingsRow(label: "Code") {
                MenuField("Code font", selection: $store.codeFace, sections: faces(code))
            }
            SettingsRow(label: "More fonts") {
                Button("Install Fonts\u{2026}") { installing = true }
                    .buttonStyle(.station)
                    .fixedSize()
            }
        }
        SettingsSection(title: "Preview", note: "Code is sized to the body font's x-height. Source mode (⌥⌘U) sets the whole page in the code font.") {
            FontPreview(store: store, colors: colors)
        }
    }

    /// Downloads the pairing's missing catalog families one at a time, then sets all three slots. A failed or stopped
    /// download ends it there and leaves the fonts as they were.
    private func apply(_ pairing: Pairing) {
        let missing = pairing.missing
        pairingFailure = nil
        guard !missing.isEmpty else { return set(pairing) }
        applying = pairing.name
        Task {
            defer { applying = nil }
            for family in missing {
                await library.startInstall(family).value
                guard Faces.exists(family.name) else {
                    pairingFailure = library.failures[family.name].map { "\(pairing.name) needs \(family.name). \($0)" }
                    return
                }
            }
            set(pairing)
        }
    }

    private func set(_ pairing: Pairing) {
        store.bodyFace = pairing.body
        store.headingFace = pairing.heading
        store.codeFace = pairing.code
    }
}

/// Settings > Appearance > Install Fonts: the catalog and the fonts added from files.
struct FontLibrarySheet: View {
    let store: ThemeStore
    let library: FontLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var filter = CatalogFilter.all
    @State private var notice: String?
    @State private var outcomes: [FontLibrary.Outcome] = []
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        let addedMono = Set(library.added.filter(\.monospaced).map(\.family))
        VStack(spacing: 0) {
            Form {
                Section {
                    TextChoice(label: "Show", selection: $filter, options: CatalogFilter.allCases.map { ($0.rawValue, $0) })
                    let families = FontCatalog.families.filter { filter.includes($0, installed: library.installed.contains($0.name)) }
                    ForEach(families) { family in
                        CatalogRow(family: family, library: library, store: store) { remove(family.name) }
                    }
                    if families.isEmpty {
                        Text("Nothing installed from the catalog yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } header: {
                    Text("Catalog")
                } footer: {
                    Text("Fonts download from google/fonts only when you click Install, and each file must match the catalog's SHA-256 before anything is installed.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    ForEach(library.addedFamilies, id: \.self) { family in
                        AddedRow(family: family, files: library.fonts(of: family), monospaced: addedMono.contains(family), library: library, store: store) {
                            remove(family)
                        }
                    }
                    DropZone(targeted: targeted) { importing = true }
                    ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                        OutcomeRow(outcome: outcome)
                    }
                } header: {
                    Text("Added")
                } footer: {
                    Text("Fonts install for Dewline only. Other apps can't see them unless you choose Install for All Apps.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let notice {
                    Label(notice, systemImage: "arrow.uturn.backward")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.station(.filled))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 620)
        .dropDestination(for: URL.self) { urls, _ in
            outcomes = library.add(urls)
            return true
        } isTargeted: {
            targeted = $0
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { outcomes = library.add(urls) }
        }
    }

    /// Moves any slot off `family` before its files go, and says so.
    private func remove(_ family: String) {
        let slots = store.release(family)
        do {
            try library.remove(family)
            notice = slots.isEmpty ? nil : "\(slots.formatted(.list(type: .and))) went back to the default because \(family) was removed."
        } catch {
            notice = "\(family) couldn't be removed. \(error.localizedDescription)"
        }
    }
}

private enum CatalogFilter: String, CaseIterable, Identifiable {
    case all = "All", serif = "Serif", sans = "Sans", mono = "Mono", display = "Display", installed = "Installed"

    var id: Self { self }

    func includes(_ family: FontCatalog.Family, installed: Bool) -> Bool {
        switch self {
        case .all: true
        case .installed: installed
        default: family.role.rawValue == rawValue
        }
    }
}

private func megabytes(_ bytes: Int) -> String {
    (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(2)))
}

/// A face at `size` when it is available, else the system font, so a family not yet installed never resolves to
/// a random fallback.
private func face(_ family: String, _ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
    Faces.exists(family) ? Font(Faces.font(family, size: size, weight: weight)) : .system(size: size, weight: weight == .medium ? .medium : .regular)
}

/// A pairing as a row set in its own heading face, with its faces in `ink3` after it. A bead on a hairline marks the
/// pairing the three slots hold.
private struct PairingRow: View {
    let pairing: Pairing
    let store: ThemeStore
    let busy: Bool
    let action: () -> Void

    var body: some View {
        let selected = store.bodyFace == pairing.body && store.headingFace == pairing.heading && store.codeFace == pairing.code
        let download = pairing.missing.reduce(0) { $0 + $1.size }
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                PairingBead(lit: selected)
                Text(pairing.name)
                    .font(face(pairing.heading, 16, weight: selected ? .medium : .regular))
                    .foregroundStyle(Station.color(selected ? .ink : .ink2))
                Text(pairing.faces.joined(separator: " \u{00B7} "))
                    .font(Station.label)
                    .foregroundStyle(Station.color(.ink3))
                    .lineLimit(1)
                if busy {
                    Text("downloading")
                        .font(Station.mono(11))
                        .foregroundStyle(Station.color(.ink3))
                } else if download > 0 {
                    Text("\(megabytes(download)) MB")
                        .font(Station.mono(11))
                        .foregroundStyle(Station.color(.ink3))
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(BareButtonStyle(radius: 4))
        .help("Body: \(pairing.body). Headings: \(pairing.heading). Code: \(pairing.code).")
        .accessibilityLabel("\(pairing.name) pairing")
        .accessibilityHint(download > 0
            ? "Body \(pairing.body), headings \(pairing.heading), code \(pairing.code). Downloads \(megabytes(download)) megabytes"
            : "Body \(pairing.body), headings \(pairing.heading), code \(pairing.code)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The mark as a radio: a 14 pt hairline, and when lit, signal with a 6 pt bead and its glow.
private struct PairingBead: View {
    let lit: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Station.color(lit ? .signal : .ink3))
                .frame(width: 14, height: 1)
            if lit {
                Circle()
                    .fill(Station.color(.signal))
                    .frame(width: 6, height: 6)
                    .shadow(color: Station.color(.glow).opacity(Double(Chrome.glowOpacity(dark: scheme == .dark))), radius: 3)
                    .offset(x: 7)
            }
        }
        .frame(width: 16, height: 8, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A family that isn't installed yet shows its specimen, drawn ahead of time by scripts/font-specimens.swift.
private struct CatalogRow: View {
    @MainActor private static var specimens: [String: NSImage] = [:]

    let family: FontCatalog.Family
    let library: FontLibrary
    let store: ThemeStore
    let remove: () -> Void
    @State private var showsInfo = false

    var body: some View {
        let installed = library.installed.contains(family.name)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if installed {
                    Text(family.name)
                        .font(face(family.name, 20))
                    Text("Public beta opens on 2 December.")
                        .font(face(family.name, 14))
                } else {
                    Image(nsImage: Self.specimen(family))
                        .renderingMode(.template)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(family.name)
                }
                Text("\(family.role.rawValue) · \(megabytes(family.size)) MB · \(family.why)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let failure = library.failures[family.name] {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action(installed: installed)
            Button {
                showsInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("About \(family.name)")
            .accessibilityLabel("About \(family.name)")
            .popover(isPresented: $showsInfo, arrowEdge: .trailing) {
                CatalogInfo(family: family)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private static func specimen(_ family: FontCatalog.Family) -> NSImage {
        if let image = specimens[family.name] { return image }
        let url = Bundle.main.url(forResource: family.name, withExtension: "pdf", subdirectory: "Specimens")
        let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        image.isTemplate = true
        specimens[family.name] = image
        return image
    }

    @ViewBuilder
    private func action(installed: Bool) -> some View {
        if let received = library.progress[family.name] {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: Double(min(received, family.size)), total: Double(family.size))
                        .frame(width: 96)
                    Text("\(megabytes(received)) of \(megabytes(family.size)) MB")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Button {
                    library.stopInstall(family)
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop")
                .accessibilityLabel("Stop downloading \(family.name)")
            }
        } else if installed {
            UseMenu(family: family.name, monospaced: family.role == .mono, library: library, store: store, remove: remove)
        } else {
            Button(library.failures[family.name] == nil ? "Install" : "Retry") {
                library.startInstall(family)
            }
            .accessibilityLabel("Install \(family.name)")
        }
    }
}

/// Only fixed-pitch families are offered for Code, as in the Code picker.
private struct UseMenu: View {
    let family: String
    let monospaced: Bool
    let library: FontLibrary
    let store: ThemeStore
    let remove: () -> Void

    var body: some View {
        Menu("Use") {
            Toggle("Use for Body", isOn: slot(\.bodyFace))
            Toggle("Use for Headings", isOn: slot(\.headingFace))
            if monospaced {
                Toggle("Use for Code", isOn: slot(\.codeFace))
            }
            Divider()
            Button("Install for All Apps…") { library.installForAllApps(family) }
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
        .fixedSize()
        .accessibilityLabel("Use \(family)")
    }

    private func slot(_ path: ReferenceWritableKeyPath<ThemeStore, String>) -> Binding<Bool> {
        Binding {
            store[keyPath: path] == family
        } set: {
            if $0 { store[keyPath: path] = family }
        }
    }
}

private struct CatalogInfo: View {
    let family: FontCatalog.Family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(family.name).font(.headline)
            Text(family.license)
            Link("Project page", destination: URL(string: family.project)!)
            Link("Files at google/fonts \(FontCatalog.commit.prefix(7))", destination: URL(string: "https://github.com/google/fonts/tree/\(FontCatalog.commit)/ofl/\(family.folder)")!)
            Divider()
            ForEach(family.files, id: \.name) { file in
                LabeledContent(file.name, value: "\(megabytes(file.size)) MB")
                    .font(.caption)
            }
            Text("Each file is checked against its SHA-256 before it installs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

private struct AddedRow: View {
    let family: String
    let files: [URL]
    let monospaced: Bool
    let library: FontLibrary
    let store: ThemeStore
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(family).font(face(family, 17))
                Text(files.map(\.lastPathComponent).formatted(.list(type: .and)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            UseMenu(family: family, monospaced: monospaced, library: library, store: store, remove: remove)
        }
        .padding(.vertical, 2)
    }
}

private struct DropZone: View {
    let targeted: Bool
    let add: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Drop .ttf, .otf or .ttc files here")
                .foregroundStyle(targeted ? .primary : .secondary)
            Button("Add Font Files…", action: add)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4]))
        }
        .padding(.vertical, 4)
    }
}

private struct OutcomeRow: View {
    let outcome: FontLibrary.Outcome

    var body: some View {
        switch outcome {
        case .added(let family):
            Label("Added \(family)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .alreadyAdded(let family):
            Label("\(family) is already added", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .refused(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// A heading, a paragraph and a code line set as the editor sets them, on the current theme's paper.
struct FontPreview: View {
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
        .background(color(.paper), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Station.color(.hairline), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
