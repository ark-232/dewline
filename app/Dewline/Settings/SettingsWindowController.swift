import AppKit
import SwiftUI

/// Dewline > Settings: a preferences toolbar with one tab per pane, each pane a SwiftUI form. The window takes the
/// pane's name and opens on the pane last shown.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    @objc static func showSettings(_ sender: Any?) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.showWindow(sender)
    }

    private convenience init() {
        let store = ThemeStore.shared
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.pane("General", "gearshape", GeneralPane(preferences: .shared, updates: .shared)))
        tabs.addTabViewItem(Self.pane("Appearance", "paintpalette", AppearancePane(store: store, library: .shared)))
        tabs.addTabViewItem(Self.pane("Editor", "character.cursor.ibeam", EditorPane(store: store)))
        tabs.addTabViewItem(Self.pane("Files", "folder", FilesPane(preferences: .shared)))
        tabs.addTabViewItem(Self.pane("Agents", "dot.radiowaves.left.and.right", AgentsPane(store: store)))
        tabs.addTabViewItem(Self.pane("Collaboration", "person.2", CollaborationPane(preferences: .shared, store: store)))
        let last = UserDefaults.standard.string(forKey: SettingsTabs.paneKey)
        tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex { $0.label == last } ?? 0
        let window = NSWindow(contentViewController: tabs)
        // No miniaturize or resize: the minimize and zoom buttons show dimmed.
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isRestorable = false
        window.title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        window.center()
        self.init(window: window)
    }

    private static func pane(_ title: String, _ symbol: String, _ form: some View) -> NSTabViewItem {
        // A long pane scrolls in its form; at its full height Appearance ran past the bottom of the screen.
        let controller = NSHostingController(rootView: form.formStyle(.grouped).frame(width: 640).frame(maxHeight: 720))
        controller.sizingOptions = .preferredContentSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}

private final class SettingsTabs: NSTabViewController {
    static let paneKey = "DewlineSettingsPane"

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let label = tabViewItem?.label else { return }
        view.window?.title = label
        UserDefaults.standard.set(label, forKey: Self.paneKey)
    }
}

/// The last row of every pane: puts that pane's settings, and no others, back as a fresh install has them.
struct RestoreDefaults: View {
    let restore: () -> Void

    var body: some View {
        Section {
        } footer: {
            HStack {
                Spacer()
                Button("Restore Defaults", action: restore)
            }
        }
    }
}
