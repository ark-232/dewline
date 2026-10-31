import AppKit

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let window = windowMenu()
        let help = helpMenu()
        for menu in [appMenu(), fileMenu(), editMenu(), formatMenu(), viewMenu(), goMenu(), window, help] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApplication.shared.windowsMenu = window
        NSApplication.shared.helpMenu = help
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
        let snapshots = NSMenu(title: "Snapshots")
        snapshots.delegate = SnapshotsMenu.shared
        menu.addItem(withTitle: "Snapshots", action: nil, keyEquivalent: "").submenu = snapshots
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
        menu.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = findMenu()
        menu.addItem(withTitle: "Go to Line…", action: #selector(CaretTextView.goToLine(_:)), keyEquivalent: "l")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Smart Punctuation", action: #selector(EditorTextView.toggleSmartPunctuation(_:)), keyEquivalent: "")
        menu.addItem(format(.moveLineUp, "[", [.command, .option]))
        menu.addItem(format(.moveLineDown, "]", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Keep Change", action: #selector(EditorTextView.keepChange(_:)), keyEquivalent: "\r")
        let revert = menu.addItem(withTitle: "Revert Change", action: #selector(EditorTextView.revertChange(_:)), keyEquivalent: "\u{8}")
        revert.keyEquivalentModifierMask = [.command, .option]
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        for (command, key, modifiers): (MarkdownFormat, String, NSEvent.ModifierFlags) in [
            (.bold, "b", .command), (.italic, "i", .command), (.strikethrough, "X", .command), (.highlight, "H", .command),
            (.code, "C", .command), (.link, "k", .command),
        ] {
            menu.addItem(format(command, key, modifiers))
        }
        menu.addItem(.separator())
        for (command, key) in zip([MarkdownFormat.heading1, .heading2, .heading3, .heading4, .heading5, .heading6, .body], ["1", "2", "3", "4", "5", "6", "0"]) {
            menu.addItem(format(command, key, .command))
        }
        menu.addItem(.separator())
        for (command, key, modifiers): (MarkdownFormat, String, NSEvent.ModifierFlags) in [
            (.quote, "'", .command), (.bulletedList, "8", [.command, .shift]), (.numberedList, "7", [.command, .shift]), (.task, "9", [.command, .shift]),
        ] {
            menu.addItem(format(command, key, modifiers))
        }
        return menu
    }

    private static func format(_ command: MarkdownFormat, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: command.name, action: #selector(EditorTextView.format(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = command.rawValue
        return item
    }

    private static func findMenu() -> NSMenu {
        let menu = NSMenu(title: "Find")
        let find = menu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(withTitle: "Find in Files…", action: #selector(MainWindowController.findInFiles(_:)), keyEquivalent: "F")
        menu.addItem(.separator())
        let next = menu.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let previous = menu.addItem(withTitle: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "G")
        previous.tag = NSTextFinder.Action.previousMatch.rawValue
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Command Palette…", action: #selector(AppDelegate.showCommandPalette(_:)), keyEquivalent: "P")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Review Changes", action: #selector(ReviewPanel.toggleReview(_:)), keyEquivalent: "R").target = ReviewPanel.shared
        menu.addItem(withTitle: "Follow Changes", action: #selector(ReviewPanel.toggleFollow(_:)), keyEquivalent: "").target = ReviewPanel.shared
        menu.addItem(.separator())
        let sidebar = menu.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let source = menu.addItem(withTitle: "Show Source", action: #selector(EditorTextView.toggleSource(_:)), keyEquivalent: "u")
        source.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Focus", action: #selector(EditorTextView.toggleFocusMode(_:)), keyEquivalent: "D")
        menu.addItem(withTitle: "Typewriter", action: #selector(EditorTextView.toggleTypewriterMode(_:)), keyEquivalent: "T")
        menu.addItem(.separator())
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        for (title, action, key, shift) in [
            ("Fold", #selector(EditorTextView.foldBlock(_:)), left, false), ("Unfold", #selector(EditorTextView.unfoldBlock(_:)), right, false),
            ("Fold All", #selector(EditorTextView.foldAll(_:)), left, true), ("Unfold All", #selector(EditorTextView.unfoldAll(_:)), right, true),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = shift ? [.command, .option, .shift] : [.command, .option]
        }
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(withTitle: "Back", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        menu.addItem(withTitle: "Forward", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "]")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let welcome = menu.addItem(withTitle: "Launch Window", action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "1")
        welcome.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Welcome to Dewline", action: #selector(AppDelegate.showWelcomeGuide(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Watch a Change Land (Demo)", action: #selector(AppDelegate.runWelcomeDemo(_:)), keyEquivalent: "")
        return menu
    }
}
