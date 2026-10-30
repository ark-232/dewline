import AppKit

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let window = windowMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApplication.shared.windowsMenu = window
        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Dewline")
        menu.addItem(withTitle: "About Dewline", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = Updates.shared
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(SettingsWindowController.showSettings(_:)), keyEquivalent: ",")
        settings.target = SettingsWindowController.self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Dewline", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dewline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "New Tab", action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        menu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let folder = menu.addItem(withTitle: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o")
        folder.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Quick Open…", action: #selector(AppDelegate.quickOpen(_:)), keyEquivalent: "O")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        menu.addItem(.separator())
        let html = menu.addItem(withTitle: "Export as HTML…", action: #selector(MarkdownDocument.exportDocument(_:)), keyEquivalent: "")
        html.tag = Export.Format.html.rawValue
        let pdf = menu.addItem(withTitle: "Export as PDF…", action: #selector(MarkdownDocument.exportDocument(_:)), keyEquivalent: "E")
        pdf.tag = Export.Format.pdf.rawValue
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        let find = menu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let next = menu.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let previous = menu.addItem(withTitle: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "G")
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        menu.addItem(withTitle: "Go to Line…", action: #selector(CaretTextView.goToLine(_:)), keyEquivalent: "l")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Command Palette…", action: #selector(AppDelegate.showCommandPalette(_:)), keyEquivalent: "P")
        menu.addItem(.separator())
        let sidebar = menu.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let source = menu.addItem(withTitle: "Show Source", action: #selector(EditorTextView.toggleSource(_:)), keyEquivalent: "u")
        source.keyEquivalentModifierMask = [.command, .option]
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let welcome = menu.addItem(withTitle: "Welcome to Dewline", action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "1")
        welcome.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}
