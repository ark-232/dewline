import AppKit
import SwiftUI

/// The Help menu's links and windows, and the About panel's acknowledgements.
@MainActor
final class Help: NSObject {
    static let docs = URL(string: "https://github.com/ark-232/dewline/tree/main/docs")!
    static let releases = URL(string: "https://github.com/ark-232/dewline/releases")!
    static let cliSetup = URL(string: "https://github.com/ark-232/dewline/blob/main/docs/hooks.md")!
    private static var shortcuts: NSWindowController?

    @objc static func openDocs(_ sender: Any?) {
        NSWorkspace.shared.open(docs)
    }

    @objc static func openReleaseNotes(_ sender: Any?) {
        NSWorkspace.shared.open(releases)
    }

    @objc static func openCLISetup(_ sender: Any?) {
        NSWorkspace.shared.open(cliSetup)
    }

    /// A new issue with an empty title and the app's and macOS's versions in the body.
    @objc static func reportIssue(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var issue = URLComponents(string: "https://github.com/ark-232/dewline/issues/new")!
        issue.queryItems = [
            URLQueryItem(name: "title", value: ""),
            URLQueryItem(name: "body", value: "\n\n---\nDewline \(version) (\(build))\nmacOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n"),
        ]
        // URLComponents leaves "+" alone, which a query reads as a space.
        issue.percentEncodedQuery = issue.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if let url = issue.url { NSWorkspace.shared.open(url) }
    }

    @objc static func showKeyboardShortcuts(_ sender: Any?) {
        if shortcuts == nil {
            let controller = NSHostingController(rootView: ShortcutList(groups: ShortcutList.groups()))
            let window = NSWindow(contentViewController: controller)
            window.title = "Keyboard Shortcuts"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 460, height: 600))
            window.isRestorable = false
            window.center()
            shortcuts = NSWindowController(window: window)
        }
        shortcuts?.showWindow(sender)
    }

    /// The standard About panel, with a line pointing to the bundled third-party notices.
    @objc static func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Dewline contains open-source software. ",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            credits.append(NSAttributedString(string: "Acknowledgements", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .link: notices,
            ]))
            credits.append(NSAttributedString(string: " lists each component, its license and its source.", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// Help > Keyboard Shortcuts: every shortcut in the menu bar MainMenu builds, by menu, filtered as you type.
private struct ShortcutList: View {
    struct Row: Identifiable {
        let id: Int
        let title: String
        let key: KeyEquivalent
    }

    struct Group: Identifiable {
        var id: String { menu }
        let menu: String
        let rows: [Row]
    }

    let groups: [Group]
    @State private var query = ""
    @FocusState private var searching: Bool

    static func groups() -> [Group] {
        var groups: [Group] = []
        var next = 0
        func walk(_ menu: NSMenu, _ path: [String]) {
            // A menu's own rows go before its submenus'.
            let index = groups.count
            var rows: [Row] = []
            for item in menu.items {
                if let submenu = item.submenu {
                    walk(submenu, path + [submenu.title])
                } else if !item.keyEquivalent.isEmpty {
                    rows.append(Row(id: next, title: item.title, key: KeyEquivalent(item.keyEquivalent, item.keyEquivalentModifierMask)))
                    next += 1
                }
            }
            if !rows.isEmpty { groups.insert(Group(menu: path.joined(separator: " › "), rows: rows), at: index) }
        }
        walk(MainMenu.bar().main, [])
        return groups
    }

    private var shown: [Group] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            let rows = group.rows.filter { row in
                let haystack = "\(group.menu) \(row.title) \(row.key.glyphs) \(row.key.spoken)".lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            return rows.isEmpty ? nil : Group(menu: group.menu, rows: rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Type to find a command or a key"))
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .padding(12)
            List {
                ForEach(shown) { group in
                    Section(group.menu) {
                        ForEach(group.rows) { row in
                            HStack {
                                Text(row.title)
                                Spacer()
                                Text(row.key.glyphs)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(row.key.spoken)
                        }
                    }
                }
            }
            .overlay {
                if shown.isEmpty {
                    Text("No shortcut matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 360)
        .onAppear { searching = true }
    }
}
