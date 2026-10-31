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

    let share: Share
    private let id: UUID
    private weak var document: NSDocument?
    private weak var textView: EditorTextView?
    private let carets = RemoteCaretsView()
    /// A local edit made during a composition has not reached the share yet.
    private var behind = false
    private var applying = false
    private var opening = false
    private var ended = false
    private var storedKey: Data?

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
            nodeKey: SyncKeychain.nodeKey(), name: NSFullUserName(), fileName: document.fileURL?.lastPathComponent ?? "Shared.md",
            text: textView.string, changed: notifier(id))
        let collaboration = Collaboration(share: share, id: id)
        live[id] = collaboration
        collaboration.attach(document, textView)
        collaboration.storeKey()
        return collaboration
    }

    /// Asks for the name the host will see, then joins through `link`.
    static func join(link: String) {
        let alert = NSAlert()
        alert.messageText = "Join a shared document"
        alert.informativeText = "The person sharing it sees this name and lets you in."
        let field = NSTextField(string: NSFullUserName())
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = UUID()
        do {
            let share = try Share.join(nodeKey: SyncKeychain.nodeKey(), name: field.stringValue, link: link, changed: notifier(id))
            live[id] = Collaboration(share: share, id: id)
        } catch {
            presentFailure("Dewline couldn’t join.", error.message)
        }
    }

    private static func presentFailure(_ message: String, _ detail: String) {
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
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func storeKey() {
        guard let key = share.documentKey, key != storedKey else { return }
        SyncKeychain.write(key, as: "document " + share.shareID)
        storedKey = key
    }

    /// A guest's copy of the shared file: in Documents/Dewline Shared under the host's file name, which the share
    /// has already reduced to a bare name.
    private func openShared() {
        guard !opening else { return }
        opening = true
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Dewline Shared")
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
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] document, _, error in
                guard let self else { return }
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
        share.close()
        Self.live[id] = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        if let message { Self.presentFailure("Sharing ended.", message) }
    }
}

/// Collaborators' carets: thin, steady lines in the collaborator writer hue, with the name on hover.
final class RemoteCaretsView: NSView {
    /// The collaborator writer hue (design synthesis: OKLCH 0.56 0.20 350, 0.72 0.17 350 in dark).
    static let hue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? OKLCH(l: 0.72, c: 0.17, h: 350).color : OKLCH(l: 0.56, c: 0.20, h: 350).color
    }

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
