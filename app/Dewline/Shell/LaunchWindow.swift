import AppKit

/// The window shown when nothing is open: the wordmark, how to start, and the files you had open.
final class LaunchWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static var showsWhenNothingIsOpen: Bool {
        // The test host stays windowless.
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && UserDefaults.standard.object(forKey: "ShowLaunchWindow") as? Bool ?? true
    }

    private enum Row {
        case group(URL)
        case item(URL, isFolder: Bool, date: Date?)
    }

    private let list = LaunchList()
    private let segments = NSSegmentedControl(labels: ["Recent", "Pinned", "Folders"], trackingMode: .selectOne, target: nil, action: nil)
    private let filter = NSSearchField()
    private let empty = NSTextField(labelWithString: "")
    private let wordmark = NSTextField(labelWithString: "")
    private let tagline = NSTextField(labelWithString: "Nothing changes behind your back.")
    private let version = NSTextField(labelWithString: "")
    private let underline = Stroke(LaunchWindowController.cobalt)
    private let horizon = Stroke(.clear)
    private var rows: [Row] = []
    /// First lines of files and paths of folders, empty for a file or folder that no longer exists.
    private var previews: [URL: String] = [:]
    private var branches: [URL: String] = [:]
    private static var entered = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Dewline"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.contentView = content()
        window.initialFirstResponder = list
        window.autorecalculatesKeyViewLoop = true
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Library.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: ThemeStore.didChange, object: nil)
        applyTheme()
        reload()
    }

    /// The wordmark in the theme's ink, the tagline and version in its second ink, and the horizon in its syntax ink.
    @objc private func applyTheme() {
        let store = ThemeStore.shared
        var attributes = Self.wordmark
        attributes[.foregroundColor] = store.color(.ink)
        wordmark.attributedStringValue = NSAttributedString(string: "dewline", attributes: attributes)
        tagline.textColor = store.color(.ink2)
        version.textColor = store.color(.ink2)
        horizon.color = store.color(.syntax)
    }

    required init?(coder: NSCoder) {
        fatalError("LaunchWindowController is built in code")
    }

    /// The first time per launch, the window rises 10 pt as it fades in and the rules draw in; under
    /// Reduce Motion it only fades.
    override func showWindow(_ sender: Any?) {
        guard let window, !window.isVisible, !Self.entered else { return super.showWindow(sender) }
        Self.entered = true
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = window.frame
        window.alphaValue = 0
        if !still { window.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - 10)) }
        super.showWindow(sender)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = still ? 0.15 : 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
        if !still {
            underline.drawIn(after: 0.08, over: 0.24)
            horizon.drawIn(after: 0.16, over: 0.3)
        }
    }

    private func content() -> NSView {
        let left = BackdropView()
        let right = PaperView()

        let icon = NSImageView(image: Self.icon)
        let actions = NSStackView(views: [
            LaunchAction("New Document", symbol: "square.and.pencil", shortcut: "⌘N", action: #selector(AppDelegate.newDocument(_:))),
            LaunchAction("Open…", symbol: "folder", shortcut: "⌘O", action: #selector(NSDocumentController.openDocument(_:))),
            LaunchAction("Open Folder…", symbol: "folder.badge.plus", shortcut: "⌥⌘O", action: #selector(AppDelegate.openFolder(_:))),
        ])
        actions.orientation = .vertical
        actions.spacing = 2
        let info = Bundle.main.infoDictionary ?? [:]
        version.stringValue = "Version \(info["CFBundleShortVersionString"] ?? "") (\(info["CFBundleVersion"] ?? ""))"
        version.font = .systemFont(ofSize: 11)

        segments.selectedSegment = 0
        segments.target = self
        segments.action = #selector(reload)
        filter.placeholderString = "Filter"
        filter.delegate = self
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.headerView = nil
        list.style = .inset
        list.backgroundColor = .clear
        list.allowsTypeSelect = false
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(openSelected)
        list.onKey = { [weak self] event in self?.handle(event) ?? false }
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        let shows = NSButton(checkboxWithTitle: "Show this window when nothing is open", target: self, action: #selector(toggleShows(_:)))
        shows.controlSize = .small
        shows.font = .systemFont(ofSize: 11)
        shows.state = Self.showsWhenNothingIsOpen ? .on : .off

        let root = NSView()
        for view in [left, right] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [icon, wordmark, underline, tagline, horizon, actions, version] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(view)
        }
        for view in [segments, filter, scroll, empty, shows] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 300),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 760),
            root.heightAnchor.constraint(equalToConstant: 460),

            icon.topAnchor.constraint(equalTo: left.topAnchor, constant: 48),
            icon.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            wordmark.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
            wordmark.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            // The underline sits under "line"; a label's text starts 2 pt in.
            underline.leadingAnchor.constraint(equalTo: wordmark.leadingAnchor, constant: 2 + Self.width("dew")),
            underline.widthAnchor.constraint(equalToConstant: Self.width("line") - 0.4),
            underline.topAnchor.constraint(equalTo: wordmark.firstBaselineAnchor, constant: 5),
            underline.heightAnchor.constraint(equalToConstant: 2.5),
            tagline.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 6),
            tagline.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            horizon.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 20),
            horizon.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            horizon.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            horizon.heightAnchor.constraint(equalToConstant: 1),
            actions.topAnchor.constraint(equalTo: horizon.bottomAnchor, constant: 16),
            actions.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
            version.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -18),
            version.centerXAnchor.constraint(equalTo: left.centerXAnchor),

            segments.topAnchor.constraint(equalTo: right.topAnchor, constant: 18),
            segments.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            filter.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 12),
            filter.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
            filter.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: shows.topAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -12),
            shows.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 20),
            shows.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -14),
        ])
        for action in actions.arrangedSubviews {
            action.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
        }
        // Dusk's and Nightwatch's skies meet their horizon at the line.
        left.horizon = horizon.centerYAnchor
        return root
    }

    @objc private func reload() {
        let query = filter.stringValue
        func matches(_ url: URL) -> Bool {
            query.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
        switch segments.selectedSegment {
        case 0:
            var groups: [(folder: URL, visits: [Library.Visit])] = []
            for visit in Library.recents where matches(visit.url) {
                let folder = visit.url.deletingLastPathComponent()
                if let index = groups.firstIndex(where: { $0.folder == folder }) {
                    groups[index].visits.append(visit)
                } else {
                    groups.append((folder, [visit]))
                }
            }
            rows = groups.flatMap { group in
                [.group(group.folder)] + group.visits.map { .item($0.url, isFolder: false, date: $0.date) }
            }
        case 1:
            rows = Library.pins.filter(matches).map { .item($0, isFolder: $0.hasDirectoryPath, date: nil) }
        default:
            rows = Library.recentFolders.filter { matches($0.url) }.map { .item($0.url, isFolder: true, date: $0.date) }
        }
        list.reloadData()
        if let first = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) {
            list.selectRowIndexes([first], byExtendingSelection: false)
        }
        empty.stringValue = !query.isEmpty ? "Nothing matches \u{201C}\(query)\u{201D}."
            : ["Files you open appear here.", "Right-click a file in the sidebar to pin it.", "Folders you open appear here."][segments.selectedSegment]
        empty.isHidden = !rows.isEmpty
        loadDetails()
    }

    /// Reads each file's first line and each folder's branch off the main thread, after the first frame.
    private func loadDetails() {
        let items = rows.compactMap { row -> (URL, Bool)? in
            guard case .item(let url, let isFolder, _) = row, previews[url] == nil else { return nil }
            return (url, isFolder)
        }
        let folders = rows.compactMap { row -> URL? in
            guard case .group(let url) = row, branches[url] == nil else { return nil }
            return url
        }
        guard !items.isEmpty || !folders.isEmpty else { return }
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                var previews: [URL: String] = [:]
                for (url, isFolder) in items {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        previews[url] = ""
                        continue
                    }
                    if isFolder {
                        previews[url] = abbreviatedPath(url)
                        continue
                    }
                    let handle = try? FileHandle(forReadingFrom: url)
                    let data = (try? handle?.read(upToCount: 4096)) ?? nil
                    try? handle?.close()
                    previews[url] = data.flatMap { firstProseLine(of: String(decoding: $0, as: UTF8.self)) } ?? " "
                }
                var branches: [URL: String] = [:]
                for url in folders {
                    branches[url] = gitBranch(at: url) ?? ""
                }
                return (previews, branches)
            }.value
            previews.merge(found.0) { $1 }
            branches.merge(found.1) { $1 }
            list.reloadData(forRowIndexes: IndexSet(integersIn: 0..<list.numberOfRows), columnIndexes: [0])
        }
    }

    @objc private func openSelected() {
        guard list.selectedRow >= 0, case .item(let url, let isFolder, _) = rows[list.selectedRow] else { return }
        if isFolder {
            (NSApp.delegate as? AppDelegate)?.openFolder(at: url)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    /// Return opens, Delete forgets a recent file, and typing goes to the filter.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            openSelected()
            return true
        case 51, 117:
            guard segments.selectedSegment == 0, list.selectedRow >= 0,
                case .item(let url, _, _) = rows[list.selectedRow]
            else { return false }
            Library.forget(url)
            return true
        default:
            guard event.specialKey == nil, event.modifierFlags.isDisjoint(with: [.command, .control]),
                let characters = event.characters, !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return false }
            window?.makeFirstResponder(filter)
            filter.currentEditor()?.insertText(characters)
            return true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    @objc private func toggleShows(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "ShowLaunchWindow")
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return row == 0 ? 24 : 34 }
        return 46
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let folder):
            let cell = tableView.makeView(withIdentifier: GroupCell.identifier, owner: nil) as? GroupCell ?? GroupCell()
            cell.show(folder, branch: branches[folder])
            return cell
        case .item(let url, let isFolder, let date):
            let cell = tableView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
            cell.show(url, isFolder: isFolder, preview: previews[url], date: date)
            return cell
        }
    }

    // MARK: Brand

    private static let cobalt = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.429, green: 0.615, blue: 0.961, alpha: 1)
            : NSColor(srgbRed: 0.191, green: 0.374, blue: 0.81, alpha: 1)
    }

    private static let wordmark: [NSAttributedString.Key: Any] = [
        .font: NSFont(descriptor: NSFont.systemFont(ofSize: 30, weight: .medium).fontDescriptor.withDesign(.serif)!, size: 30)!,
        .kern: -0.4,
    ]

    private static func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: wordmark).size().width
    }

    /// The app icon as the spec draws it: a cobalt tile with a glass pane rising from its bottom edge,
    /// an ink line with a cobalt underline, and a struck grey line.
    private static let icon = NSImage(size: NSSize(width: 96, height: 96), flipped: true) { rect in
        let s = rect.width
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.06, dy: s * 0.06), xRadius: s * 0.2, yRadius: s * 0.2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 5
        shadow.shadowColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.4, alpha: 0.35)
        shadow.set()
        NSColor(srgbRed: 0.16, green: 0.25, blue: 0.7, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(
            starting: NSColor(srgbRed: 0.174, green: 0.374, blue: 0.867, alpha: 1),
            ending: NSColor(srgbRed: 0.143, green: 0.129, blue: 0.553, alpha: 1)
        )!.draw(in: tile, angle: 90)
        NSGradient(
            starting: NSColor(srgbRed: 0.194, green: 0.525, blue: 0.915, alpha: 0.9),
            ending: NSColor(srgbRed: 0.194, green: 0.525, blue: 0.915, alpha: 0)
        )!.draw(in: tile, relativeCenterPosition: NSPoint(x: -0.4, y: -0.9))
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        let pane = NSRect(x: s * 0.24, y: s * 0.42, width: s * 0.52, height: s * 0.6)
        NSGradient(
            starting: NSColor(srgbRed: 0.986, green: 0.995, blue: 1, alpha: 0.97),
            ending: NSColor(srgbRed: 0.907, green: 0.939, blue: 0.974, alpha: 0.94)
        )!.draw(in: NSBezierPath(roundedRect: pane, xRadius: s * 0.08, yRadius: s * 0.08), angle: 90)
        func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: NSColor) {
            color.setFill()
            let bar = NSRect(x: pane.minX + pane.width * x, y: pane.minY + pane.height * y, width: pane.width * width, height: s * height)
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        }
        bar(0.16, 0.18, 0.62, 0.05, NSColor(srgbRed: 0.101, green: 0.132, blue: 0.189, alpha: 1))
        bar(0.52, 0.31, 0.26, 0.03, NSColor(srgbRed: 0.176, green: 0.33, blue: 0.827, alpha: 1))
        bar(0.16, 0.5, 0.5, 0.04, NSColor(srgbRed: 0.705, green: 0.72, blue: 0.745, alpha: 1))
        bar(0.12, 0.515, 0.58, 0.014, NSColor(srgbRed: 0.433, green: 0.446, blue: 0.469, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
}

/// The recents list, passing keys it doesn't use to the launch window.
private final class LaunchList: NSTableView {
    var onKey: (NSEvent) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }
}

/// A borderless action row: a symbol, a title, and its shortcut on the right.
private final class LaunchAction: NSControl {
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    init(_ title: String, symbol: String, shortcut: String, action: Selector) {
        super.init(frame: .zero)
        self.action = action
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let key = NSTextField(labelWithString: shortcut)
        key.textColor = .secondaryLabelColor
        for view in [icon, label, key] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("LaunchAction is built in code")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: nil)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// A folder's header in the recents list: its name, its path, and its branch. The path gives way first, from the
/// middle, so the folders nearest the files stay readable.
private final class GroupCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("group")
    private let path = NSTextField(labelWithString: "")
    private let branch = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        textField = name
        for label in [path, branch] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
        }
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [name, path, branch])
        row.spacing = 8
        row.alignment = .firstBaseline
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("GroupCell is built in code")
    }

    func show(_ folder: URL, branch: String?) {
        textField?.stringValue = FileManager.default.displayName(atPath: folder.path)
        path.stringValue = abbreviatedPath(folder)
        self.branch.stringValue = "git · \(branch ?? "")"
        self.branch.isHidden = branch?.isEmpty ?? true
    }
}

/// A file in the recents list: its name and time on the first line, its first line of prose under it.
private final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")
    private static let prose = NSFont(descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor.withDesign(.serif)!.withSymbolicTraits(.italic), size: 12)

    private let preview = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let leader = DotLeader()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let icon = NSImageView()
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        imageView = icon
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = name
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, name, preview, time, leader] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            leader.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            leader.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -6),
            leader.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            leader.heightAnchor.constraint(equalToConstant: 2),
            leader.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            time.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            preview.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("FileCell is built in code")
    }

    func show(_ url: URL, isFolder: Bool, preview text: String?, date: Date?) {
        let gone = text?.isEmpty == true
        imageView?.image = NSImage(systemSymbolName: isFolder ? "folder.fill" : "doc.text", accessibilityDescription: nil)
        imageView?.contentTintColor = gone ? .tertiaryLabelColor : isFolder ? .controlAccentColor : .secondaryLabelColor
        textField?.stringValue = url.lastPathComponent
        textField?.textColor = gone ? .secondaryLabelColor : .labelColor
        preview.stringValue = gone ? "Moved or deleted" : text ?? " "
        preview.textColor = gone || isFolder ? .tertiaryLabelColor : .secondaryLabelColor
        preview.font = isFolder ? .systemFont(ofSize: 11) : Self.prose
        preview.lineBreakMode = isFolder ? .byTruncatingMiddle : .byTruncatingTail
        time.stringValue = date.map { shortDate($0) } ?? ""
        leader.isHidden = date == nil
    }
}

/// A horizontal rule that can draw itself in from the left.
private final class Stroke: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }
    private let shape = CAShapeLayer()

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) {
        fatalError("Stroke is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        shape.strokeColor = color.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: bounds.midY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        shape.frame = bounds
        shape.path = path
        shape.lineWidth = bounds.height
        CATransaction.commit()
    }

    func drawIn(after delay: CFTimeInterval, over duration: CFTimeInterval) {
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = CACurrentMediaTime() + delay
        draw.duration = duration
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.add(draw, forKey: "draw")
    }
}
