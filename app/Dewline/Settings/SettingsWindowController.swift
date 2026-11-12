import AppKit
import SwiftUI

/// Dewline > Settings: a standard preferences window, 640 by 480, with one toolbar button per pane. It opens on the
/// pane last shown.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    static let paneKey = "DewlineSettingsPane"
    static let size = NSSize(width: 640, height: 480)

    @objc static func showSettings(_ sender: Any?) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.showWindow(sender)
    }

    private convenience init() {
        let last = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init) ?? .general
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane))
            host.sizingOptions = []
            // The tab view controller titles the window from the selected pane's controller.
            host.title = pane.rawValue
            host.view.frame.size = Self.size
            let item = NSTabViewItem(viewController: host)
            item.label = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: last) ?? 0
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = last.rawValue
        window.isRestorable = false
        window.setContentSize(Self.size)
        window.center()
        self.init(window: window)
    }
}

/// Remembers the pane each time one is picked.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let name = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(name, forKey: SettingsWindowController.paneKey)
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", editor = "Editor", appearance = "Appearance", files = "Files", agents = "Agents"
    case sharing = "Sharing"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editor: "character.cursor.ibeam"
        case .appearance: "paintpalette"
        case .files: "folder"
        case .agents: "terminal"
        case .sharing: "person.2"
        }
    }
}

/// One pane's settings on the window's background.
private struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        content
            .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height, alignment: .top)
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
        case .sharing: CollaborationPane(preferences: .shared, store: store)
        }
    }
}
