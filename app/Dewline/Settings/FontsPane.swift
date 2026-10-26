import SwiftUI
import UniformTypeIdentifiers

struct FontsPane: View {
    @Bindable var store: ThemeStore
    let library: FontLibrary
    @Environment(\.colorScheme) private var scheme
    @State private var filter = CatalogFilter.all
    @State private var applying: String?
    @State private var notice: String?
    @State private var outcomes: [FontLibrary.Outcome] = []
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        let colors = scheme == .dark ? store.darkTheme.darkColors : store.lightTheme.lightColors
        let mac = library.macFamilies
        let ours = library.installed.union(library.addedFamilies)
        let catalogMono = library.installed.filter { FontCatalog.family($0)?.role == .mono }
        let addedMono = Set(library.added.filter(\.monospaced).map(\.family))
        Form {
            Section {
                FacePicker(title: "Body", selection: $store.bodyFace, sections: [
                    ("System", Faces.system), ("Bundled", Faces.bundled), ("Catalog", library.installed.sorted()),
                    ("Added", library.addedFamilies), ("This Mac", mac.all.filter { !ours.contains($0) }),
                ])
                FacePicker(title: "Headings", selection: $store.headingFace, sections: [
                    ("System", Faces.system), ("Bundled", Faces.bundled), ("Catalog", library.installed.sorted()),
                    ("Added", library.addedFamilies), ("This Mac", mac.all.filter { !ours.contains($0) }),
                ])
                FacePicker(title: "Code", selection: $store.codeFace, sections: [
                    ("System", ["SF Mono"]), ("Bundled", Faces.bundled), ("Catalog", catalogMono.sorted()),
                    ("Added", addedMono.sorted()), ("This Mac", mac.monospaced.filter { !ours.contains($0) }),
                ])
            } header: {
                FontPreview(store: store, colors: colors)
            } footer: {
                Group {
                    if let notice {
                        Label(notice, systemImage: "arrow.uturn.backward")
                    } else {
                        Text("Code is sized to the body font's x-height. Source mode (⌥⌘U) sets the whole page in the code font.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Pairing.all) { pairing in
                        PairingButton(pairing: pairing, store: store, library: library, colors: colors, busy: applying == pairing.name) {
                            apply(pairing)
                        }
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Pairings")
            } footer: {
                Text("A pairing sets the body, heading and code fonts at once, downloading any it needs from the catalog.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(CatalogFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
        .frame(minHeight: 520, idealHeight: 760)
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

    /// Downloads the pairing's missing catalog families, then sets all three slots; a failed or stopped download
    /// leaves the fonts as they were.
    private func apply(_ pairing: Pairing) {
        let missing = Set(pairing.faces.filter { !Faces.exists($0) }).compactMap(FontCatalog.family)
        guard !missing.isEmpty else { return set(pairing) }
        applying = pairing.name
        Task {
            for family in missing {
                await library.startInstall(family).value
            }
            applying = nil
            if pairing.faces.allSatisfy(Faces.exists) { set(pairing) }
        }
    }

    private func set(_ pairing: Pairing) {
        store.bodyFace = pairing.body
        store.headingFace = pairing.heading
        store.codeFace = pairing.code
        notice = nil
    }

    /// Moves any slot off `family` before its files go, and says so under the slots.
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

private struct FacePicker: View {
    let title: String
    @Binding var selection: String
    let sections: [(String, [String])]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(sections.filter { !$0.1.isEmpty }, id: \.0) { section in
                Section(section.0) {
                    ForEach(section.1, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }
}

private func megabytes(_ bytes: Int) -> String {
    (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(2)))
}

/// A face at `size` when it is available, else the system font, so a family not yet installed never resolves to
/// a random fallback.
private func face(_ family: String, _ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
    Faces.exists(family) ? Font(Faces.font(family, size: size, weight: weight)) : .system(size: size, weight: Font.Weight(weight))
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        self = weight == .medium ? .medium : weight == .semibold ? .semibold : .regular
    }
}

/// "Aa" in the pairing's heading and body faces on the current theme's paper, its name, and its three faces; a ring
/// marks the pairing the slots hold.
private struct PairingButton: View {
    let pairing: Pairing
    let store: ThemeStore
    let library: FontLibrary
    let colors: [Token: NSColor]
    let busy: Bool
    let action: () -> Void

    var body: some View {
        let selected = store.bodyFace == pairing.body && store.headingFace == pairing.heading && store.codeFace == pairing.code
        let download = Set(pairing.faces.filter { !Faces.exists($0) }).compactMap(FontCatalog.family).reduce(0) { $0 + $1.size }
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Aa").font(face(pairing.heading, 30, weight: .medium)).foregroundStyle(Color(nsColor: colors[.heading]!))
                    Text("Aa").font(face(pairing.body, 19)).foregroundStyle(Color(nsColor: colors[.ink]!))
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color(nsColor: colors[.paper]!), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if busy {
                        ProgressView().controlSize(.small).padding(6)
                    }
                }
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(pairing.name)
                    .font(.callout)
                    .foregroundStyle(selected ? .primary : .secondary)
                Text(download > 0 ? "Downloads \(megabytes(download)) MB" : [pairing.heading, pairing.body, pairing.code].reduce(into: [String]()) {
                    if !$0.contains($1) { $0.append($1) }
                }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Body: \(pairing.body). Headings: \(pairing.heading). Code: \(pairing.code).")
        .accessibilityLabel("\(pairing.name) pairing")
        .accessibilityHint("Body \(pairing.body), headings \(pairing.heading), code \(pairing.code)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A specimen row: the family's name and a sample line in its own face once installed, its role, size and why, and
/// Install, the download's progress with Stop, or Use once installed.
private struct CatalogRow: View {
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
                    // The same two lines, drawn ahead of time as outlines by scripts/font-specimens.swift.
                    Image(nsImage: specimen(family))
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

@MainActor private var specimens: [String: NSImage] = [:]

/// The family's name and sample line as a template image, from the app's Specimens folder.
@MainActor private func specimen(_ family: FontCatalog.Family) -> NSImage {
    if let image = specimens[family.name] { return image }
    let url = Bundle.main.url(forResource: family.name, withExtension: "pdf", subdirectory: "Specimens")
    let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    image.isTemplate = true
    specimens[family.name] = image
    return image
}

/// The pull-down on an installed family: which slots use it, Install for All Apps, Remove. Only fixed-pitch families
/// are offered for Code, as in the Code picker.
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

/// A dropped-in family: its name in its face, its files, and the same pull-down as the catalog's rows.
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

/// A heading, a paragraph and a code line set as the editor sets them, on the current theme's paper. It heads the
/// face pickers' section rather than sitting in a section of its own, so it is one card, not a card in a card.
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
        .background(color(.paper), in: .rect(cornerRadius: 10))
        // The header insets its content to the rows' text; the card keeps to the section's edges.
        .padding(.horizontal, -10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
