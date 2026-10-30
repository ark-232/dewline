import AppKit
import MdCore
import os

/// A document's file as the change engine keeps it: watched, with outside writes landed into the editor and saves
/// made through the engine. Engine calls other than `commit` run off the main thread, one at a time.
@MainActor
final class LiveFile {
    /// A landed change or conflict, by its live range in the buffer.
    struct Change: Equatable {
        var range: NSRange
        let marked: Bool
        let conflict: Bool
    }

    let engine: ChangeEngine
    let doc: UInt64
    private(set) var url: URL
    /// Quiet changes until the next commit, since a late claim can relabel them; marked changes and conflicts until
    /// they are decided.
    private(set) var changes: [UInt64: Change] = [:]
    private weak var document: MarkdownDocument?
    private let queue = DispatchQueue(label: "dev.arkwerx.dewline.engine", qos: .utility)
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var debounce: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var autosaving: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
    private var refreshAgain = false
    /// A landing waits for a composition or Writing Tools session to end.
    private var landingWaits = false
    /// The engine refused the last autosave; it runs again when the refusing state ends.
    private var autosaveRefused = false
    private var applying = false
    private var closed = false
    private static let log = Logger(subsystem: "dev.arkwerx.dewline", category: "engine")

    init(engine: ChangeEngine, doc: UInt64, url: URL, document: MarkdownDocument) {
        self.engine = engine
        self.doc = doc
        self.url = url
        self.document = document
        arm()
    }

    /// Follows the editor's edits and input sessions.
    func attach(_ textView: EditorTextView) {
        textView.edited = { [weak self] range, delta in self?.edited(range, delta: delta) }
        textView.inputEnded = { [weak self] in self?.inputEnded() }
    }

    func close() {
        closed = true
        for source in sources { source.cancel() }
        sources = []
        for task in [debounce, retry, autosaving] { task?.cancel() }
        let (engine, doc) = (engine, doc)
        queue.async { engine.close(doc) }
    }

    /// The file is now at `url`.
    func moved(to url: URL) {
        self.url = url
        arm()
        let (engine, doc) = (engine, doc)
        queue.async {
            do throws(ChangeEngine.Failure) {
                try engine.moved(doc, to: url)
            } catch {
                Self.log.error("The engine lost a moved file: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Detection

    /// Vnode sources on the file and its folder. A source on the file follows its inode, so each signal arms them
    /// again on whatever file is at the path then.
    private func arm() {
        for source in sources { source.cancel() }
        sources = []
        guard !closed else { return }
        let file: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .attrib, .link, .revoke]
        for (path, events) in [(url.path, file), (url.deletingLastPathComponent().path, .write)] {
            let fd = Darwin.open(path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.signal() } }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    /// Something changed at the file or in its folder: arm again and land 150 ms after the last signal.
    func signal() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            arm()
            await refresh()
        }
    }

    // MARK: Landing

    /// Observes the file and lands its new version into the buffer, until the buffer holds it, nothing is left to
    /// land, or the landing waits. A call while one runs makes it go round once more and waits for it.
    func refresh() async {
        refreshAgain = true
        if let refreshing { return await refreshing.value }
        let task = Task {
            while refreshAgain, !closed {
                refreshAgain = false
                await landOnce()
            }
            refreshing = nil
        }
        refreshing = task
        await task.value
    }

    private func landOnce() async {
        guard let textView = document?.textView, !waitsForInput(textView) else { return }
        let (buffer, version) = (textView.string, textView.version)
        let (engine, doc) = (engine, doc)
        let result = await offMain { () -> Result<ChangeEngine.Landing?, ChangeEngine.Failure> in
            Result { () throws(ChangeEngine.Failure) in
                try engine.observe(doc) ? try engine.land(doc, buffer: buffer, version: version) : nil
            }
        }
        let landing: ChangeEngine.Landing
        switch result {
        case .success(let landed?): landing = landed
        case .success(nil), .failure(.closed): return
        case .failure(.waiting):
            retry?.cancel()
            retry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
            return
        case .failure(let failure):
            Self.log.error("A change to the file did not land: \(String(describing: failure), privacy: .public)")
            return
        }
        guard !closed, document?.textView === textView, !waitsForInput(textView) else { return }
        // A newer edit or observation supersedes the landing: land again.
        guard textView.version == landing.version, engine.commit(doc, landing: landing.id) else {
            refreshAgain = true
            return
        }
        apply(landing, to: textView, clean: buffer == document?.text)
    }

    private func waitsForInput(_ textView: EditorTextView) -> Bool {
        landingWaits = textView.hasMarkedText() || textView.isWritingToolsActive
        return landingWaits
    }

    /// Applies a committed landing as one storage edit outside undo, keeping the selection by its neighbors and the
    /// caret's line, else the first visible line, where it is on screen.
    private func apply(_ landing: ChangeEngine.Landing, to textView: EditorTextView, clean: Bool) {
        let storage = textView.textStorage!
        let edits = landing.edits
        func map(_ offset: Int, _ bias: ChangeEngine.Bias) -> Int {
            ChangeEngine.map(offset, through: edits, bias: bias)
        }
        let selection = textView.selectedRanges.map(\.rangeValue)
        let visible = textView.visibleRect
        // TextKit 2 answers a point in the top inset with an index near the end of the text, so probes stay below it.
        func index(_ x: CGFloat, _ y: CGFloat) -> Int {
            textView.characterIndexForInsertion(at: NSPoint(x: x, y: max(y, textView.textContainerOrigin.y)))
        }
        let first = index(visible.minX, visible.minY)
        let caret = selection.first?.location ?? first
        let anchor = first <= caret && caret <= index(visible.maxX, visible.maxY) ? caret : first
        let offset = textView.baseline(at: min(anchor, storage.length - 1)).map { $0 - visible.minY }

        applying = true
        storage.beginEditing()
        for edit in (landing.covering.map { [$0] } ?? edits).reversed() {
            storage.replaceCharacters(in: edit.range, with: edit.text)
        }
        storage.endEditing()
        applying = false

        let mapped = selection.map { range in
            guard range.length > 0 else { return NSRange(location: map(range.location, .before), length: 0) }
            let start = map(range.location, .after)
            return NSRange(location: start, length: max(map(NSMaxRange(range), .before) - start, 0))
        }
        textView.setSelectedRanges(mapped.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        if let offset { textView.hold(map(anchor, .before), at: offset) }
        // Undo entries from before the landing would put back the wrong text.
        textView.breakUndoCoalescing()
        textView.undoManager?.removeAllActions()

        changes = changes.filter { $0.value.marked || $0.value.conflict }.mapValues { change in
            var change = change
            let start = map(change.range.location, .after)
            change.range = NSRange(location: start, length: max(map(NSMaxRange(change.range), .before) - start, 0))
            return change
        }
        var shift = 0
        for edit in edits {
            let length = edit.text.utf16.count
            changes[edit.change] = Change(range: NSRange(location: edit.range.location + shift, length: length), marked: landing.marked, conflict: false)
            shift += length - edit.range.length
        }
        for conflict in landing.conflicts {
            let start = map(conflict.range.location, .after)
            let range = NSRange(location: start, length: max(map(NSMaxRange(conflict.range), .before) - start, 0))
            changes[conflict.change] = Change(range: range, marked: true, conflict: true)
        }

        if clean {
            document?.absorbed(textView.string)
        } else {
            scheduleAutosave()
        }
    }

    // MARK: Edits and saves

    private func edited(_ range: NSRange, delta: Int) {
        guard !applying else { return }
        let oldEnd = NSMaxRange(range) - delta
        func moved(_ offset: Int) -> Int {
            offset < range.location ? offset : offset >= oldEnd ? offset + delta : NSMaxRange(range)
        }
        changes = changes.mapValues { change in
            var change = change
            let start = min(moved(change.range.location), change.range.location)
            change.range = NSRange(location: start, length: moved(NSMaxRange(change.range)) - start)
            return change
        }
        scheduleAutosave()
    }

    private func inputEnded() {
        if landingWaits { Task { await refresh() } }
        if autosaveRefused { Task { await autosave() } }
    }

    /// Autosaves 2 s after the last edit.
    private func scheduleAutosave() {
        autosaving?.cancel()
        autosaving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.autosave()
        }
    }

    /// Saves the buffer unless the engine refuses, which puts it in the file's draft instead.
    @discardableResult
    func autosave() async -> ChangeEngine.Refusal? {
        autosaving?.cancel()
        guard let textView = document?.textView else { return nil }
        let refusal = await save(.auto(composing: textView.hasMarkedText(), writingTools: textView.isWritingToolsActive))
        autosaveRefused = refusal != nil
        return refusal
    }

    /// Cmd-S: lands what the file holds, then saves.
    func saveExplicitly() async -> ChangeEngine.Refusal? {
        await refresh()
        let refusal = await save(.explicit)
        if refusal == nil { autosaveRefused = false }
        return refusal
    }

    private func save(_ kind: ChangeEngine.SaveKind) async -> ChangeEngine.Refusal? {
        guard !closed, let document, let textView = document.textView else { return .closed }
        let (buffer, version) = (textView.string, textView.version)
        let token = document.changeCountToken(for: .saveOperation)
        let (engine, doc) = (engine, doc)
        let result = await offMain { () -> Result<Data, ChangeEngine.Refusal> in
            Result { () throws(ChangeEngine.Refusal) in try engine.save(doc, buffer: buffer, version: version, kind: kind) }
        }
        switch result {
        case .success:
            document.saved(buffer, token: token)
            return nil
        case .failure(let refusal):
            return refusal
        }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
