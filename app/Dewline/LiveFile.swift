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
        var origin: ChangeEngine.Origin
        var marked: Bool
        let conflict: Bool
    }

    let engine: ChangeEngine
    let doc: UInt64
    private(set) var url: URL
    /// Quiet changes until the next commit, since a late claim can relabel them; marked changes and conflicts until
    /// they are decided.
    private(set) var changes: [UInt64: Change] = [:]
    /// The file's snapshots, newest first, as last read off the main thread for the Snapshots menu.
    private(set) var snapshots: [ChangeEngine.Snapshot] = []
    private var gitdir: URL?
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
    private nonisolated static let log = Logger(subsystem: "dev.arkwerx.dewline", category: "engine")

    init(engine: ChangeEngine, doc: UInt64, url: URL, gitdir: URL?, document: MarkdownDocument) {
        self.engine = engine
        self.doc = doc
        self.url = url
        self.document = document
        Self.open[Key(engine, doc)] = self
        watchGit(gitdir)
        arm()
        reloadSnapshots()
    }

    /// Follows the editor's edits and input sessions.
    func attach(_ textView: EditorTextView) {
        textView.edited = { [weak self] range, delta in self?.edited(range, delta: delta) }
        textView.inputEnded = { [weak self] in self?.inputEnded() }
    }

    func close() {
        closed = true
        Self.open[Key(engine, doc)] = nil
        watchGit(nil)
        for source in sources { source.cancel() }
        sources = []
        for task in [debounce, retry, autosaving] { task?.cancel() }
        let (engine, doc) = (engine, doc)
        queue.async { engine.close(doc) }
    }

    /// The file is now at `url`.
    func moved(to url: URL) {
        guard url.standardizedFileURL != self.url.standardizedFileURL else { return }
        self.url = url
        arm()
        let (engine, doc) = (engine, doc)
        queue.async { [weak self] in
            let result = Result { () throws(ChangeEngine.Failure) in try engine.moved(doc, to: url) }
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .success(let gitdir): self.watchGit(gitdir)
                case .failure(let error):
                    Self.log.error("The engine lost a moved file: \(String(describing: error), privacy: .public)")
                }
                self.reloadSnapshots()
            }
        }
    }

    // MARK: Claims and git

    private struct Key: Hashable {
        let engine: ObjectIdentifier
        let doc: UInt64

        init(_ engine: ChangeEngine, _ doc: UInt64) {
            self.engine = ObjectIdentifier(engine)
            self.doc = doc
        }
    }

    /// Open files by engine and document, since claims and git name documents.
    private static var open: [Key: LiveFile] = [:]
    private static let claims = DispatchQueue(label: "dev.arkwerx.dewline.claims", qos: .utility)

    /// Sends a hook's claim to `engine` and acts on what it changed.
    static func claim(_ claim: ControlSocket.Claim, engine: ChangeEngine) {
        // The engine parses the line's fields again; Stop stands for every turn's end.
        let (event, use, path): (String, ControlSocket.Claim.ToolUse?, String?) =
            switch claim.event {
            case .preToolUse(let use): ("PreToolUse", use, use.path)
            case .postToolUse(let use): ("PostToolUse", use, use.path)
            case .instructionsLoaded(let path): ("InstructionsLoaded", nil, path)
            case .turnEnd: ("Stop", nil, nil)
            case .sessionEnd: ("SessionEnd", nil, nil)
            }
        claims.async {
            let updates = engine.claim(
                event: event, vendor: claim.vendor.rawValue, session: claim.session, toolUseId: use?.id,
                tool: use?.tool.rawValue, path: path, hash: use?.hash, declared: use?.declared)
            guard !updates.isEmpty else { return }
            Task { @MainActor in
                for update in updates {
                    switch update {
                    case .relabeled(let doc, let change, let origin):
                        open[Key(engine, doc)]?.relabel(change, origin: origin)
                    case .released(let doc):
                        open[Key(engine, doc)]?.released()
                    case .retry(let doc):
                        if let live = open[Key(engine, doc)] { Task { await live.refresh() } }
                    }
                }
            }
        }
    }

    private func relabel(_ change: UInt64, origin: ChangeEngine.Origin) {
        changes[change]?.origin = origin
        changes[change]?.marked = true
    }

    /// A hold on the file ended.
    func released() {
        if autosaveRefused { Task { await autosave() } }
    }

    /// One vnode source per gitdir, shared by the open files in its repository.
    private final class GitWatch {
        let source: any DispatchSourceFileSystemObject
        var files = 0
        var debounce: Task<Void, Never>?

        init(_ source: any DispatchSourceFileSystemObject) {
            self.source = source
        }
    }

    private static var gitWatches: [String: GitWatch] = [:]

    private func watchGit(_ gitdir: URL?) {
        if let old = self.gitdir, let watch = Self.gitWatches[old.path] {
            watch.files -= 1
            if watch.files == 0 {
                watch.source.cancel()
                watch.debounce?.cancel()
                Self.gitWatches[old.path] = nil
            }
        }
        self.gitdir = gitdir
        guard let gitdir else { return }
        if let watch = Self.gitWatches[gitdir.path] {
            watch.files += 1
            return
        }
        let fd = Darwin.open(gitdir.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link], queue: .main)
        let watch = GitWatch(source)
        watch.files = 1
        let engine = engine
        // git's locks come and go in the gitdir: index.lock, HEAD.lock, ORIG_HEAD.
        source.setEventHandler { [weak watch] in
            MainActor.assumeIsolated {
                guard let watch else { return }
                watch.debounce?.cancel()
                watch.debounce = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    let docs = await withCheckedContinuation { continuation in
                        Self.claims.async { continuation.resume(returning: engine.gitChanged(gitdir)) }
                    }
                    for doc in docs {
                        if let live = Self.open[Key(engine, doc)] { Task { await live.refresh() } }
                    }
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        Self.gitWatches[gitdir.path] = watch
    }

    // MARK: Detection

    /// Vnode sources on the file and its folder. A source on the file follows its inode, so each signal arms them
    /// again on whatever file is at the path then.
    private func arm() {
        for source in sources { source.cancel() }
        sources = []
        fileFD = -1
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
            if path == url.path { fileFD = fd }
        }
    }

    /// The descriptor the file's source watches, while it is armed.
    private var fileFD: Int32 = -1

    /// With no file at the path, where the watched file went, if it was renamed rather than deleted.
    private func renamedPath() -> URL? {
        guard fileFD >= 0, access(url.path, F_OK) != 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fileFD, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path != url.path, access(path, F_OK) == 0 else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Something changed at the file or in its folder: arm again and land 150 ms after the last signal.
    func signal() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            // NSDocument hears of a rename only through file coordination; one seen here moves the document too.
            if let renamed = renamedPath() {
                document?.fileURL = renamed
                moved(to: renamed)
            } else {
                arm()
            }
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
                // git's lock and a hook call's end land again sooner; this covers a lock left behind.
                try? await Task.sleep(for: .seconds(1))
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
            changes[edit.change] = Change(
                range: NSRange(location: edit.range.location + shift, length: length), origin: landing.origin,
                marked: landing.marked, conflict: false)
            shift += length - edit.range.length
        }
        for conflict in landing.conflicts {
            let start = map(conflict.range.location, .after)
            let range = NSRange(location: start, length: max(map(NSMaxRange(conflict.range), .before) - start, 0))
            changes[conflict.change] = Change(range: range, origin: landing.origin, marked: true, conflict: true)
        }
        reloadSnapshots()

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

    /// Settles a change: replaces its live range with what the decision makes of it, as one undoable edit. Deciding
    /// the last conflict runs a refused autosave again.
    func decide(_ change: UInt64, _ decision: ChangeEngine.Decision) {
        guard let textView = document?.textView, let pending = changes[change] else { return }
        let current = (textView.string as NSString).substring(with: pending.range)
        let replacement = engine.decide(doc, change: change, decision: decision, current: current)
        changes[change] = nil
        if let replacement { textView.replaceAsOneEdit(pending.range, with: replacement) }
        if pending.conflict, !changes.values.contains(where: \.conflict), autosaveRefused {
            Task { await autosave() }
        }
    }

    // MARK: Snapshots

    /// Reads the snapshot list off the main thread, then calls `then`.
    func reloadSnapshots(then: (@MainActor @Sendable () -> Void)? = nil) {
        let (engine, doc) = (engine, doc)
        queue.async { [weak self] in
            let snapshots = (try? engine.snapshots(doc)) ?? []
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.snapshots = snapshots
                then?()
            }
        }
    }

    /// Replaces the buffer with the snapshot's text as one undoable edit; the buffer is snapshotted first.
    func restore(_ snapshot: ChangeEngine.Snapshot) async {
        guard let textView = document?.textView else { return }
        let (engine, doc, buffer) = (engine, doc, textView.string)
        let result = await offMain { () -> Result<String, ChangeEngine.Failure> in
            Result { () throws(ChangeEngine.Failure) in try engine.restore(doc, snapshot: snapshot, buffer: buffer) }
        }
        switch result {
        case .success(let text):
            guard !closed, document?.textView === textView else { return }
            textView.replaceAsOneEdit(NSRange(location: 0, length: (textView.string as NSString).length), with: text)
            textView.undoManager?.setActionName("Restore Snapshot")
        case .failure(let error):
            Self.log.error("A snapshot did not restore: \(String(describing: error), privacy: .public)")
        }
        reloadSnapshots()
    }

    func pin(_ snapshot: ChangeEngine.Snapshot, _ pinned: Bool) {
        let (engine, doc) = (engine, doc)
        queue.async { [weak self] in
            do throws(ChangeEngine.Failure) {
                try engine.pin(doc, snapshot: snapshot, pinned: pinned)
            } catch {
                Self.log.error("A snapshot did not pin: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor in self?.reloadSnapshots() }
        }
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
        // A refused autosave writes the draft snapshot instead.
        if refusal != nil { reloadSnapshots() }
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
            reloadSnapshots()
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
