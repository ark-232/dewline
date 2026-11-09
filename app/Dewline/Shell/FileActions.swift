import AppKit

/// Making, naming, moving and trashing notes and folders on disk, each one undoable. An open note follows its file.
@MainActor
enum FileActions {
    /// ~/Documents/Dewline: Welcome.md and Inbox.md live here, and ⌘N uses it when no folder is open.
    static var notesFolder: URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "Documents/Dewline", directoryHint: .isDirectory)
    }

    /// An empty "Untitled.md" in `folder` (or "Untitled 2.md"), created at once so it autosaves like any note.
    @discardableResult
    static func newNote(in folder: URL, undo: UndoManager? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = free("Untitled", extension: "md", in: folder)
        try Data().write(to: url, options: .withoutOverwriting)
        undo?.registerUndo(withTarget: Undo.shared) { _ in _ = try? trash(url) }
        undo?.setActionName("New Note")
        return url
    }

    /// "New Folder" in `folder` (or "New Folder 2").
    @discardableResult
    static func newFolder(in folder: URL, undo: UndoManager? = nil) throws -> URL {
        let url = free("New Folder", extension: nil, in: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        undo?.registerUndo(withTarget: Undo.shared) { _ in _ = try? trash(url) }
        undo?.setActionName("New Folder")
        return url
    }

    /// Renames `url` to `name`, keeping a note's extension when `name` has none. An open note follows.
    @discardableResult
    static func rename(_ url: URL, to name: String, undo: UndoManager? = nil) throws -> URL {
        let clean = cleaned(name)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSURLErrorKey: url]) }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let keepsExtension = !isFolder && (clean as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty
        let target = url.deletingLastPathComponent().appending(path: keepsExtension ? clean + "." + url.pathExtension : clean)
        guard target.lastPathComponent != url.lastPathComponent else { return url }
        return try relocate(url, to: target, named: "Rename", undo: undo)
    }

    /// "Name copy.md" beside `url` (or "Name copy 2.md").
    @discardableResult
    static func duplicate(_ url: URL, undo: UndoManager? = nil) throws -> URL {
        let stem = url.deletingPathExtension().lastPathComponent + " copy"
        let copy = free(stem, extension: url.pathExtension.isEmpty ? nil : url.pathExtension, in: url.deletingLastPathComponent())
        try FileManager.default.copyItem(at: url, to: copy)
        undo?.registerUndo(withTarget: Undo.shared) { _ in _ = try? trash(copy) }
        undo?.setActionName("Duplicate")
        return copy
    }

    /// Moves `url` to the Trash, closing its note first, and returns where it went. Undo puts it back.
    @discardableResult
    static func trash(_ url: URL, undo: UndoManager? = nil) throws -> URL? {
        for document in documents(at: url) { document.close() }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let undo, let trashed = trashed as URL? else { return trashed as URL? }
        undo.registerUndo(withTarget: Undo.shared) { _ in
            MainActor.assumeIsolated { _ = try? relocate(trashed, to: url, named: "Move to Trash", undo: undo) }
        }
        undo.setActionName("Move to Trash")
        return trashed
    }

    /// Moves `url` into `folder`, keeping its name, or numbering it when the name is taken there.
    @discardableResult
    static func move(_ url: URL, to folder: URL, undo: UndoManager? = nil) throws -> URL {
        let name = url.lastPathComponent
        var target = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: target.path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            target = free(stem, extension: ext.isEmpty ? nil : ext, in: folder)
        }
        return try relocate(url, to: target, named: "Move", undo: undo)
    }

    // MARK: Naming a new note

    private static var naming: [ObjectIdentifier: (observer: NSObjectProtocol, check: Task<Void, Never>?)] = [:]

    /// While `document`'s name starts with "Untitled", the first save after its first line has text renames it to
    /// that line, once: 60 characters at most, without `/` or `:`, numbered when the name is taken. Autosave writes
    /// 2 s after typing stops, so the check comes half a second after that, and again while edits wait.
    static func nameFromFirstLine(_ document: MarkdownDocument) {
        let key = ObjectIdentifier(document)
        guard naming[key] == nil, let textView = document.textView else { return }
        let observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak document] _ in
            MainActor.assumeIsolated {
                naming[key]?.check?.cancel()
                naming[key]?.check = Task { [weak document] in
                    while !Task.isCancelled, let document {
                        try? await Task.sleep(for: .milliseconds(2500))
                        guard !Task.isCancelled, !document.isDocumentEdited else { continue }
                        nameIfUntitled(document)
                        return
                    }
                }
            }
        }
        naming[key] = (observer, nil)
    }

    /// Renames `document` from its first line if it is still Untitled and has one; true once it no longer waits.
    @discardableResult
    static func nameIfUntitled(_ document: MarkdownDocument) -> Bool {
        let key = ObjectIdentifier(document)
        func done() -> Bool {
            if let waiting = naming.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(waiting.observer)
                waiting.check?.cancel()
            }
            return true
        }
        guard let url = document.fileURL, url.lastPathComponent.hasPrefix("Untitled") else { return done() }
        guard let text = document.textView?.string, let name = title(of: text) else { return false }
        let target = free(name, extension: url.pathExtension.isEmpty ? "md" : url.pathExtension, in: url.deletingLastPathComponent())
        _ = try? relocate(url, to: target, named: "Rename", undo: nil)
        return done()
    }

    /// A note's first line as a file name: Markdown's heading, list and quote marks dropped, then `cleaned`.
    static func title(of text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains { !$0.isWhitespace } }) else { return nil }
        let words = line.drop { "#>-*+ \t".contains($0) }
        let name = cleaned(String(words))
        return name.isEmpty ? nil : name
    }

    // MARK: Helpers

    /// The undo target for file actions, which have no object of their own.
    @MainActor final class Undo: NSObject {
        static let shared = Undo()
    }

    /// Moves `url` to `target`, which must be free; an open note there, or inside a moved folder, follows.
    private static func relocate(_ url: URL, to target: URL, named action: String, undo: UndoManager?) throws -> URL {
        guard !FileManager.default.fileExists(atPath: target.path) || sameFile(url, target) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: target])
        }
        let open = documents(at: url)
        try FileManager.default.moveItem(at: url, to: target)
        let from = url.standardizedFileURL.path
        for document in open {
            guard let old = document.fileURL?.standardizedFileURL.path else { continue }
            let moved = URL(filePath: target.path + old.dropFirst(from.count))
            document.fileURL = moved
            document.live?.moved(to: moved)
        }
        undo?.registerUndo(withTarget: Undo.shared) { _ in
            MainActor.assumeIsolated { _ = try? relocate(target, to: url, named: action, undo: undo) }
        }
        undo?.setActionName(action)
        return target
    }

    /// Open notes at `url`, or under it for a folder.
    private static func documents(at url: URL) -> [MarkdownDocument] {
        let path = url.standardizedFileURL.path
        return NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.filter { document in
            guard let open = document.fileURL?.standardizedFileURL.path else { return false }
            return open == path || open.hasPrefix(path + "/")
        }
    }

    /// A case-only rename on a case-insensitive volume finds the same file at the target.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let one = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
            let two = try? b.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return one.isEqual(two)
    }

    /// `stem.ext` in `folder`, or `stem 2.ext`, `stem 3.ext` and on, whichever is free first.
    static func free(_ stem: String, extension ext: String?, in folder: URL) -> URL {
        func named(_ name: String) -> URL {
            folder.appending(path: ext.map { name + "." + $0 } ?? name)
        }
        var url = named(stem)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = named("\(stem) \(number)")
            number += 1
        }
        return url
    }

    /// A name with `/` and `:` dropped, blanks trimmed, no leading dot, at most 60 characters.
    static func cleaned(_ name: String) -> String {
        var clean = String(name.filter { $0 != "/" && $0 != ":" && !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        return String(clean.prefix(60)).trimmingCharacters(in: .whitespaces)
    }
}

/// The sidebar's file commands (`FileCommand`), answered by the window that shows the sidebar. Each menu item's
/// represented object is the folder or file, or a request.
extension MainWindowController {
    @objc func newNoteInFolder(_ sender: Any?) {
        guard let folder = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { try self.openNew(FileActions.newNote(in: folder, undo: self.window?.undoManager)) }
    }

    @objc func newNoteNamed(_ sender: Any?) {
        guard let request = (sender as? NSMenuItem)?.representedObject as? NewNoteRequest else { return }
        perform {
            let url = FileActions.free((request.name as NSString).deletingPathExtension, extension: "md", in: request.folder)
            try Data().write(to: url, options: .withoutOverwriting)
            self.open(url, newTab: false)
        }
    }

    @objc func newFolderInFolder(_ sender: Any?) {
        guard let folder = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { try self.sidebar.renameNew(FileActions.newFolder(in: folder, undo: self.window?.undoManager)) }
    }

    @objc func renameItem(_ sender: Any?) {
        guard let request = (sender as? NSMenuItem)?.representedObject as? RenameRequest else { return }
        perform { try FileActions.rename(request.url, to: request.name, undo: self.window?.undoManager) }
    }

    @objc func duplicateItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { _ = try FileActions.duplicate(url, undo: self.window?.undoManager) }
    }

    @objc func trashItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        perform { _ = try FileActions.trash(url, undo: self.window?.undoManager) }
    }

    @objc func moveItems(_ sender: Any?) {
        guard let request = (sender as? NSMenuItem)?.representedObject as? MoveRequest else { return }
        perform { for url in request.urls { _ = try FileActions.move(url, to: request.folder, undo: self.window?.undoManager) } }
    }

    private func openNew(_ url: URL) {
        open(url, newTab: true)
        if let document = NSDocumentController.shared.document(for: url) as? MarkdownDocument {
            FileActions.nameFromFirstLine(document)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            if let window { presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        }
    }
}
