import AppKit

/// The main window's dividers: a 1 pt hairline in the theme's rule color.
final class StationSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }

    override var dividerColor: NSColor { Chrome.color(.rule) }
}

/// The main window's split, with a sidebar that is a plain item, so no system sidebar glass draws under it. Show
/// Sidebar collapses and expands it.
final class StationSplitController: NSSplitViewController {
    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        let split = StationSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
    }

    required init?(coder: NSCoder) {
        fatalError("StationSplitController is built in code")
    }

    private var sidebarItem: NSSplitViewItem? { splitViewItems.first }

    /// NSSplitViewController answers no for `toggleSidebar:` when no item has sidebar behavior, which would send the
    /// menu's Show Sidebar past this controller to the window, where it is disabled (B1).
    override func responds(to selector: Selector!) -> Bool {
        selector == #selector(toggleSidebar(_:)) ? sidebarItem != nil : super.responds(to: selector)
    }

    override func toggleSidebar(_ sender: Any?) {
        guard let item = sidebarItem else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            item.isCollapsed.toggle()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                item.animator().isCollapsed.toggle()
            }
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) {
            (item as? NSMenuItem)?.title = sidebarItem?.isCollapsed == false ? "Hide Sidebar" : "Show Sidebar"
            return sidebarItem != nil
        }
        return super.validateUserInterfaceItem(item)
    }
}
