import AppKit
import MdCore
import Security

/// The node key and each share's document key, in the login Keychain (record 0009).
enum SyncKeychain {
    static let service = "dev.arkwerx.dewline.sync"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, as account: String) {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    /// This Mac's node key, made on first use.
    static func nodeKey() -> Data {
        if let key = read("node"), key.count == 32 { return key }
        let key = Share.newNodeKey()
        write(key, as: "node")
        return key
    }
}

/// One shared document: the share and the text view it mirrors. Local edits go out as the user types; collaborators'
/// edits wait while an input method composes, then land as one replace with the caret kept where it was.
@MainActor
final class Collaboration {
    static let changed = Notification.Name("CollaborationChanged")
    private static var live: [UUID: Collaboration] = [:]
    /// Tests share over 127.0.0.1 with no relay, open a guest's copy without showing it, and keep keys out of the
    /// Keychain.
    static var loopback = false
    static var showsWindows = true
    static var nodeKey: () -> Data = SyncKeychain.nodeKey
    static var keepKey: (Data, String) -> Void = SyncKeychain.write

    let share: Share
    private let id: UUID
    private(set) weak var document: NSDocument?
    private weak var textView: EditorTextView?
    private let carets = RemoteCaretsView()
    /// A local edit made during a composition has not reached the share yet.
    private var behind = false
    private var applying = false
    private var opening = false
    private var ended = false
    private var storedKey: Data?
    /// The guest's window while the host decides.
    private var waitingPanel: WaitingPanel?

    private init(share: Share, id: UUID) {
        self.share = share
        self.id = id
    }

    static func of(_ document: NSDocument) -> Collaboration? {
        live.values.first { $0.document === document }
    }

    private static func notifier(_ id: UUID) -> @Sendable () -> Void {
        { Task { @MainActor in Collaboration.live[id]?.refresh() } }
    }

    /// Shares the file shown in `textView`, seeded from its text as it is now.
    static func host(_ document: MarkdownDocument, textView: EditorTextView) throws(Share.Failure) -> Collaboration {
        if let open = of(document) { return open }
        let id = UUID()
        let share = try Share.host(
            nodeKey: nodeKey(), name: Preferences.shared.collaborationName, fileName: document.fileURL?.lastPathComponent ?? "Shared.md",
            text: textView.string, loopback: loopback, changed: notifier(id))
        let collaboration = Collaboration(share: share, id: id)
        live[id] = collaboration
        collaboration.attach(document, textView)
        collaboration.storeKey()
        return collaboration
    }

    /// A dewline://join link: asks for the name the host will see, then waits in a small window until the host
    /// decides.
    static func join(link: String) {
        joinPrompt(link: link)
    }

    /// File > Join Shared Note… asks for the link too.
    static func joinPrompt(link: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Join a shared note"
        alert.informativeText = "The person sharing it sees your name and lets you in."
        let linkField = NSTextField(string: link ?? "")
        linkField.placeholderString = "dewline://join?…"
        let nameField = NSTextField(string: Preferences.shared.collaborationName)
        nameField.placeholderString = "Your name"
        let fields = NSStackView(views: link == nil ? [linkField, nameField] : [nameField])
        fields.orientation = .vertical
        fields.spacing = 8
        for field in [linkField, nameField] { field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: link == nil ? 56 : 24)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = link == nil ? linkField : nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let collaboration = try join(link: linkField.stringValue, name: nameField.stringValue)
            if showsWindows, collaboration.waitingText != nil {
                collaboration.waitingPanel = WaitingPanel(collaboration)
                collaboration.waitingPanel?.showWindow(nil)
            }
        } catch {
            presentFailure("Dewline couldn’t join.", error.message)
        }
    }

    /// Joins through `link` as `name`. The share connects, waits for the host, then opens the shared note.
    static func join(link: String, name: String) throws(Share.Failure) -> Collaboration {
        let id = UUID()
        let share = try Share.join(nodeKey: nodeKey(), name: name, link: link, loopback: loopback, changed: notifier(id))
        let collaboration = Collaboration(share: share, id: id)
        live[id] = collaboration
        return collaboration
    }

    /// What a guest sees until the host decides; nil once it is in, or for the host.
    var waitingText: String? {
        let host = share.hostName.isEmpty ? "the person who shared it" : share.hostName
        return switch share.status {
        case .connecting: "Connecting to \(host)…"
        case .waiting: "Waiting for \(host) to let you in."
        default: nil
        }
    }

    /// Every join request waiting on this Mac, for the window's status line.
    static var asking: [(collaboration: Collaboration, peer: Share.Peer)] {
        live.values.flatMap { collaboration in collaboration.share.pending.map { (collaboration, $0) } }
    }

    /// The Share popover for `document`: nothing is shared until Copy Invite Link.
    static func sharePopover(for document: MarkdownDocument) -> NSViewController {
        ShareSheet(document: document)
    }

    private static func presentFailure(_ message: String, _ detail: String) {
        guard showsWindows else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func attach(_ document: NSDocument, _ textView: EditorTextView) {
        self.document = document
        self.textView = textView
        carets.frame = textView.bounds
        carets.autoresizingMask = [.width, .height]
        textView.addSubview(carets)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(storageEdited(_:)), name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        center.addObserver(self, selector: #selector(selectionChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: textView)
        center.addObserver(self, selector: #selector(documentClosed(_:)), name: MarkdownDocument.didCloseNotification, object: document)
    }

    /// The share changed: status, people, keys or text.
    private func refresh() {
        guard !ended else { return }
        switch share.status {
        case .live:
            if document == nil { openShared() }
            storeKey()
            sync()
        case .denied:
            end(saying: "The host didn’t let you in.")
        case .removed:
            end(saying: "You were removed from “\(share.fileName)”. Your copy stays on this Mac.")
        case .failed(let message):
            end(saying: message)
        case .connecting, .waiting:
            break
        }
        waitingPanel?.update()
        if waitingText == nil {
            waitingPanel?.close()
            waitingPanel = nil
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func storeKey() {
        guard let key = share.documentKey, key != storedKey else { return }
        Self.keepKey(key, "document " + share.shareID)
        storedKey = key
    }

    /// A guest's copy of the shared file: in the Collaboration settings' folder under the host's file name, which the share
    /// has already reduced to a bare name.
    private func openShared() {
        guard !opening else { return }
        opening = true
        let folder = Preferences.shared.sharedFolder
        let name = share.fileName as NSString
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder.appending(path: share.fileName)
            var copy = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appending(path: "\(name.deletingPathExtension) \(copy).\(name.pathExtension)")
                copy += 1
            }
            try Data(share.text.utf8).write(to: url, options: .withoutOverwriting)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: Self.showsWindows) { [weak self] document, _, error in
                guard let self else { return }
                if let document, document.windowControllers.isEmpty { document.makeWindowControllers() }
                guard let document, let textView = (document.windowControllers.first as? MainWindowController)?.textView else {
                    self.end(saying: error?.localizedDescription ?? "The shared file didn’t open.")
                    return
                }
                self.attach(document, textView)
                self.sync()
            }
        } catch {
            end(saying: error.localizedDescription)
        }
    }

    /// Sends a composition's text once it commits, then lands collaborators' edits and redraws their carets.
    private func sync() {
        guard let textView, share.status == .live, !textView.hasMarkedText() else { return }
        if behind {
            let (start, end, text) = Self.differing(share.text, textView.string)
            behind = (try? share.edit(start: start, end: end, text: text)) == nil
        }
        if let edit = share.pull() { apply(edit, to: textView) }
        carets.show(share.cursors, in: textView)
    }

    /// The one replace from `old` to `new`, in UTF-16.
    private static func differing(_ old: String, _ new: String) -> (Int, Int, String) {
        let (a, b) = (Array(old.utf16), Array(new.utf16))
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let text = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return (prefix, a.count - suffix, text)
    }

    /// A collaborator's edit, outside the undo history, through the change engine, which snapshots the buffer first.
    /// The caret and selection keep their place in the text.
    private func apply(_ edit: Share.Edit, to textView: EditorTextView) {
        guard let storage = textView.textStorage else { return }
        var range = NSRange(location: edit.start, length: edit.end - edit.start)
        guard NSMaxRange(range) <= storage.length else { return }
        var text = edit.text
        if let live = (document as? MarkdownDocument)?.live {
            do {
                let edits = try live.engine.collaborate(live.doc, buffer: storage.string, edits: [.init(range: range, text: text)])
                guard let edit = edits.first else { return }
                (range, text) = (edit.range, edit.text)
            } catch {
                return end(saying: "The file stopped taking edits: \(error)")
            }
        }
        let length = text.utf16.count
        func moved(_ offset: Int) -> Int {
            offset >= NSMaxRange(range) ? offset + length - range.length : min(offset, range.location + length)
        }
        let selection = textView.selectedRange()
        applying = true
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
        applying = false
        let start = moved(selection.location)
        textView.setSelectedRange(NSRange(location: start, length: max(moved(NSMaxRange(selection)) - start, 0)))
        document?.updateChangeCount(.changeDone)
    }

    @objc private func storageEdited(_ notification: Notification) {
        guard !applying, let textView, let storage = notification.object as? NSTextStorage,
            storage.editedMask.contains(.editedCharacters), share.status == .live
        else { return }
        if textView.hasMarkedText() || behind {
            behind = true
        } else {
            let range = storage.editedRange
            let text = (storage.string as NSString).substring(with: range)
            let start = range.location
            behind = (try? share.edit(start: start, end: start + range.length - storage.changeInLength, text: text)) == nil
        }
        Task { @MainActor [weak self] in self?.sync() }
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard let textView, !textView.hasMarkedText(), share.status == .live else { return }
        share.setCursor(textView.selectedRange().location)
        // An input method ending its composition changes only the selection; the edit it held lands after this.
        Task { @MainActor [weak self] in self?.sync() }
    }

    @objc private func documentClosed(_ notification: Notification) {
        end(saying: nil)
    }

    /// Stops sharing; the file stays as it is.
    func end(saying message: String?) {
        guard !ended else { return }
        ended = true
        NotificationCenter.default.removeObserver(self)
        carets.removeFromSuperview()
        waitingPanel?.close()
        waitingPanel = nil
        share.close()
        Self.live[id] = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        if let message { Self.presentFailure("Sharing ended.", message) }
    }
}

/// A guest's wait for the host: "Waiting for Rick to let you in." and Cancel, until the host decides.
final class WaitingPanel: NSWindowController {
    private weak var collaboration: Collaboration?
    private let text = NSTextField(wrappingLabelWithString: "")

    init(_ collaboration: Collaboration) {
        self.collaboration = collaboration
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 96), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Join a shared note"
        super.init(window: panel)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let line = NSStackView(views: [spinner, text])
        line.spacing = 8
        let stack = NSStackView(views: [line, cancel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        text.widthAnchor.constraint(equalToConstant: 260).isActive = true
        panel.contentView = stack
        update()
        panel.center()
    }

    required init?(coder: NSCoder) {
        fatalError("WaitingPanel is built in code")
    }

    func update() {
        text.stringValue = collaboration?.waitingText ?? ""
    }

    @objc private func cancel(_ sender: Any?) {
        collaboration?.end(saying: nil)
        close()
    }
}

/// Collaborators' carets: thin, steady lines in ink2, with the name on hover.
final class RemoteCaretsView: NSView {
    static var hue: NSColor { ThemeStore.shared.color(.ink2) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(_ cursors: [Share.Cursor], in textView: NSTextView) {
        subviews.forEach { $0.removeFromSuperview() }
        guard let window = textView.window else { return }
        let length = (textView.string as NSString).length
        for cursor in cursors {
            let range = NSRange(location: min(cursor.offset, length), length: 0)
            let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
            guard screen != .zero else { continue }
            let rect = convert(window.convertFromScreen(screen), from: nil)
            let mark = CaretMark(frame: NSRect(x: rect.minX - 3, y: rect.minY, width: 7, height: max(rect.height, 14)))
            mark.toolTip = cursor.name
            addSubview(mark)
        }
    }
}

private final class CaretMark: NSView {
    override func draw(_ dirtyRect: NSRect) {
        RemoteCaretsView.hue.setFill()
        NSRect(x: bounds.midX - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
