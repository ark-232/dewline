import AppKit
import SwiftUI

/// Dewline > Settings, built like the main window: a band of `frame` under the traffic lights, then two islands, the
/// pane list and the pane. The window takes the pane's name and opens on the pane last shown.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    static let paneKey = "DewlineSettingsPane"

    @objc static func showSettings(_ sender: Any?) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.showWindow(sender)
    }

    private convenience init() {
        let last = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init) ?? .general
        // No miniaturize or resize: the minimize and zoom buttons show dimmed.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isRestorable = false
        window.title = last.rawValue
        let frame = FrameView()
        let root = NSHostingView(rootView: SettingsRoot(pane: last) { [weak window] pane in
            window?.title = pane.rawValue
            UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey)
        })
        root.sizingOptions = []
        root.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: frame.topAnchor, constant: TitleBand.height),
            root.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -6),
            root.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -6),
        ])
        window.contentView = frame
        window.center()
        self.init(window: window)
        paintFrame()
        NotificationCenter.default.addObserver(self, selector: #selector(paintFrame), name: ThemeStore.didChange, object: nil)
    }

    /// The window's own background matches the frame, so nothing lighter shows at its rounded corners.
    @objc private func paintFrame() {
        window?.backgroundColor = Chrome.color(.frame)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", editor = "Editor", files = "Files", agents = "Agents"
    case collaboration = "Collaboration"

    var id: Self { self }

    /// The line under the pane's title.
    var summary: String {
        switch self {
        case .general: "What opens at launch, where new files go, and updates."
        case .appearance: "Themes, faces and the page. Changes apply as you pick."
        case .editor: "How the page renders, moves and checks what you type."
        case .files: "What the sidebar lists, where pasted images go, and the inbox."
        case .agents: "The hooks that name who wrote a change, and each writer's color."
        case .collaboration: "Your name, where shared copies go, and a collaborator's color."
        }
    }
}

/// The pane list island and the pane island.
private struct SettingsRoot: View {
    @State var pane: SettingsPane
    let changed: (SettingsPane) -> Void

    var body: some View {
        HStack(spacing: 5) {
            PaneList(selection: $pane)
                .frame(width: 200)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Island(fill: .islandSide))
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pane.rawValue)
                        .font(Font(Chrome.paneTitle))
                        .kerning(-0.22)
                        .foregroundStyle(Station.color(.ink))
                        .accessibilityAddTraits(.isHeader)
                    Text(pane.summary)
                        .font(Station.label)
                        .foregroundStyle(Station.color(.ink3))
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 16)
                PaneHorizon()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Island(fill: .islandEditor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .onChange(of: pane) { changed(pane) }
    }

    @ViewBuilder
    private var content: some View {
        let store = ThemeStore.shared
        switch pane {
        case .general: GeneralPane(preferences: .shared, updates: .shared)
        case .appearance: AppearancePane(store: store, library: .shared)
        case .editor: EditorPane(store: store)
        case .files: FilesPane(preferences: .shared)
        case .agents: AgentsPane(store: store)
        case .collaboration: CollaborationPane(preferences: .shared, store: store)
        }
    }
}

/// The panes as rows: Bricolage 13 in `ink2`, the open pane in `ink` on the signal wash with the tick. The up and down
/// arrows move through them.
private struct PaneList: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                Button(pane.rawValue) { selection = pane }
                    .buttonStyle(PaneRowStyle(selected: selection == pane))
                    .accessibilityAddTraits(selection == pane ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings panes")
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let panes = SettingsPane.allCases
        guard let index = panes.firstIndex(of: selection) else { return .ignored }
        selection = panes[min(max(index + step, 0), panes.count - 1)]
        return .handled
    }
}

private struct PaneRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        PaneRow(configuration: configuration, selected: selected)
    }
}

private struct PaneRow: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .font(selected ? Station.labelActive : Station.label)
            .foregroundStyle(Station.color(selected || configuration.isPressed ? .ink : .ink2))
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Station.wash)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Station.color(.signal))
                                .frame(width: contrast == .increased ? 3 : 2, height: 14)
                                .padding(.leading, 4)
                        }
                }
            }
            // Every row hears the focusable list's focus; only the open pane's row shows it.
            .overlay { FocusRing(on: focused && selected) }
            .contentShape(.rect)
            .focusEffectDisabled()
    }
}
