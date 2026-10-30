import AppKit
import SwiftUI

/// Dewline > Settings: a preferences toolbar with one tab per pane, each pane a SwiftUI form.
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    @objc static func showSettings(_ sender: Any?) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.showWindow(sender)
    }

    private convenience init() {
        let store = ThemeStore.shared
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.pane("General", "gearshape", GeneralPane(preferences: .shared)))
        tabs.addTabViewItem(Self.pane("Appearance", "paintpalette", AppearancePane(store: store)))
        tabs.addTabViewItem(Self.pane("Editor", "character.cursor.ibeam", EditorPane(store: store)))
        tabs.addTabViewItem(Self.pane("Fonts", "textformat", FontsPane(store: store, library: .shared)))
        tabs.addTabViewItem(Self.pane("Files", "folder", FilesPane(preferences: .shared)))
        tabs.addTabViewItem(Self.pane("Agents", "dot.radiowaves.left.and.right", AgentsPane()))
        tabs.addTabViewItem(Self.pane("Updates", "arrow.triangle.2.circlepath", UpdatesPane(updates: .shared)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isRestorable = false
        window.center()
        self.init(window: window)
    }

    private static func pane(_ title: String, _ symbol: String, _ form: some View) -> NSTabViewItem {
        let controller = NSHostingController(rootView: form.formStyle(.grouped).frame(width: 640))
        controller.sizingOptions = .preferredContentSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}
