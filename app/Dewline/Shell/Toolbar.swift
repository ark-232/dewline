import AppKit

/// The main window's unified toolbar, in three groups: the sidebar, Back and Forward on the leading side; the window's
/// title, which is the note's name over its folder's; Preview, Agent and Share on the trailing side. Every item is
/// also in the menu bar, and each sends its action up the responder chain.
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    static let sidebar = NSToolbarItem.Identifier("dev.arkwerx.dewline.sidebar")
    static let back = NSToolbarItem.Identifier("dev.arkwerx.dewline.back")
    static let forward = NSToolbarItem.Identifier("dev.arkwerx.dewline.forward")
    static let preview = NSToolbarItem.Identifier("dev.arkwerx.dewline.preview")
    static let agent = NSToolbarItem.Identifier("dev.arkwerx.dewline.agent")
    static let share = NSToolbarItem.Identifier("dev.arkwerx.dewline.share")

    let toolbar = NSToolbar(identifier: "dev.arkwerx.dewline.main")
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func item(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        items[identifier]
    }

    /// The number of people editing the note with you, on the Share button; nothing when no one is.
    func showEditing(_ count: Int) {
        let badge: NSItemBadge? = count > 0 ? .count(count) : nil
        guard let share = items[Self.share], share.badge != badge else { return }
        share.badge = badge
        share.toolTip = count > 0 ? "Share (\(count) editing)" : "Share"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebar, Self.back, Self.forward, .flexibleSpace, Self.preview, Self.agent, Self.share]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case Self.sidebar:
            item = Self.button(identifier, "Sidebar", symbol: "sidebar.left", tip: "Show or hide the sidebar (⌃⌘S)", action: #selector(NSSplitViewController.toggleSidebar(_:)))
        case Self.back:
            item = Self.button(identifier, "Back", symbol: "chevron.left", tip: "Back (⌘[)", action: #selector(MainWindowController.goBack(_:)))
        case Self.forward:
            item = Self.button(identifier, "Forward", symbol: "chevron.right", tip: "Forward (⌘])", action: #selector(MainWindowController.goForward(_:)))
        case Self.preview:
            item = Self.button(identifier, "Preview", symbol: "doc.richtext", tip: "Preview beside the text (⌥⌘P)", action: #selector(MainWindowController.togglePreview(_:)))
        case Self.agent:
            item = Self.button(identifier, "Agent", symbol: "bubble.left.and.text.bubble.right", tip: "Chat with your coding agent (⌥⌘A)", action: #selector(MainWindowController.toggleAgent(_:)))
        case Self.share:
            item = Self.button(identifier, "Share", symbol: "square.and.arrow.up", tip: "Share", action: #selector(MainWindowController.shareDocument(_:)))
        default:
            return nil
        }
        items[identifier] = item
        return item
    }

    private static func button(_ identifier: NSToolbarItem.Identifier, _ label: String, symbol: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.action = action
        item.autovalidates = true
        // Navigation sits at the leading edge, before the title.
        item.isNavigational = [Self.sidebar, Self.back, Self.forward].contains(identifier)
        return item
    }
}
