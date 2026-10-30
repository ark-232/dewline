import AppKit
import MdCore
import os

/// A markdown file. Saving writes only while the file still holds the bytes it was opened or last saved with.
final class MarkdownDocument: NSDocument {
    private static let bom = Data([0xEF, 0xBB, 0xBF])

    /// The text as opened or last saved; the tab's text view holds the edits.
    private(set) var text = ""
    /// The hash of the file's bytes as opened or last saved.
    private var baseHash = contentHash(Data())
    private var hasBOM = false
    /// `dewline open --wait` connections, answered when this document closes.
    private var waiters: [ControlSocket.Connection] = []
    /// The engine that opens the file; none reads and saves it directly. Set only before the document reads, which
    /// may happen off the main thread.
    nonisolated(unsafe) var engine = MarkdownDocument.sharedEngine
    /// The file as the engine keeps it, once read.
    private(set) var live: LiveFile?

    /// The app's engine, its snapshots in Application Support. The test host has none; tests make their own.
    nonisolated static let sharedEngine: ChangeEngine? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            return try ChangeEngine(store: support.appending(path: "dev.arkwerx.dewline/snapshots"))
        } catch {
            Logger(subsystem: "dev.arkwerx.dewline", category: "engine")
                .error("No change engine, so files save without it: \(String(describing: error), privacy: .public)")
            return nil
        }
    }()

    /// Posted when a document closes.
    static let didCloseNotification = Notification.Name("MarkdownDocumentDidClose")

    /// True while a `dewline open --wait` client waits for this document to close.
    var isAwaited: Bool {
        waiters.contains(where: \.isOpen)
    }

    override class var autosavesInPlace: Bool {
        false
    }

    /// The engine reads, hashes and snapshots the file, so AppKit opens documents off the main thread.
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        true
    }

    /// Opens the file at `url` as Markdown, whatever its extension, reading it off the main thread.
    static func open(_ url: URL) async throws -> MarkdownDocument {
        let document = MarkdownDocument()
        try await Task.detached { try document.read(from: url, ofType: type) }.value
        document.fileURL = url
        document.fileType = type
        document.fileModificationDate = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return document
    }

    nonisolated static let type = "net.daringfireball.markdown"

    func answerWhenClosed(_ connection: ControlSocket.Connection) {
        waiters.removeAll { !$0.isOpen }
        waiters.append(connection)
    }

    override func close() {
        live?.close()
        live = nil
        super.close()
        for waiter in waiters {
            waiter.reply(.closed)
        }
        waiters = []
        NotificationCenter.default.post(name: Self.didCloseNotification, object: self)
    }

    /// Reads through a descriptor that must be a regular file, so a path that became a FIFO or a device after it
    /// was checked fails at once instead of blocking. Runs off the main thread when AppKit opens a document.
    override func read(from url: URL, ofType typeName: String) throws {
        if let engine {
            return try open(url, with: engine)
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code: CocoaError.Code = errno == ENOENT ? .fileReadNoSuchFile : errno == EACCES ? .fileReadNoPermission : .fileReadUnknown
            throw CocoaError(code, userInfo: [NSURLErrorKey: url])
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        try read(from: file.readToEnd() ?? Data(), ofType: typeName)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        Self.onMain {
            text = decoded
            baseHash = contentHash(data)
            hasBOM = data.starts(with: Self.bom)
        }
    }

    /// Runs `body` on the main thread, waiting for it from a concurrent read.
    private nonisolated static func onMain<T: Sendable>(_ body: @MainActor () throws -> T) rethrows -> T {
        guard !Thread.isMainThread else { return try MainActor.assumeIsolated(body) }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
    }

    /// Opens the file through `engine`, which reads it as `read(from:ofType:)` does and keeps it from then on.
    private nonisolated func open(_ url: URL, with engine: ChangeEngine) throws {
        Self.onMain {
            live?.close()
            live = nil
        }
        let opened: ChangeEngine.Opened
        do throws(ChangeEngine.Failure) {
            opened = try engine.open(url)
        } catch {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url, NSLocalizedFailureReasonErrorKey: "\(error)"])
        }
        guard let text = opened.text else {
            engine.close(opened.doc)
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
        }
        Self.onMain {
            self.text = text
            hasBOM = opened.bom
            let live = LiveFile(engine: engine, doc: opened.doc, url: url, gitdir: opened.gitdir, document: self)
            if let textView { live.attach(textView) }
            self.live = live
        }
    }

    var textView: EditorTextView? {
        (windowControllers.first as? MainWindowController)?.textView
    }

    /// A landing left the buffer equal to the file.
    func absorbed(_ text: String) {
        self.text = text
    }

    /// The engine wrote `text`.
    func saved(_ text: String, token: Any) {
        self.text = text
        updateChangeCount(withToken: token, for: .saveOperation)
        if let fileURL, let date = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date {
            fileModificationDate = date
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        bytes(of: shownText)
    }

    private var shownText: String {
        textView?.string ?? text
    }

    /// Decoding drops a byte-order mark, so the file's own goes back in front.
    private func bytes(of text: String) -> Data {
        (hasBOM ? Self.bom : Data()) + Data(text.utf8)
    }

    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        // AppKit refuses a file whose date moved and offers to save over it; writeSafely compares content instead.
        if let fileURL, let date = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date {
            fileModificationDate = date
        }
        super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
    }

    /// Saving the engine's file goes through it, Save As onto that same file included, and a file saved under a new
    /// name opens through it again.
    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let ownFile = live.map { live in
            url.standardizedFileURL == live.url.standardizedFileURL || Self.identity(of: url).map { $0 == Self.identity(of: live.url) } ?? false
        } ?? false
        guard let live, saveOperation == .saveOperation || saveOperation == .saveAsOperation, ownFile else {
            super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
                if error == nil, saveOperation == .saveAsOperation, let self, let engine = self.engine {
                    try? self.open(url, with: engine)
                }
                completionHandler(error)
            }
            return
        }
        Task {
            let refusal = await live.saveExplicitly()
            completionHandler(refusal.map { refusal in
                switch refusal {
                case .conflict, .changed: SaveConflict(document: self, name: url.lastPathComponent)
                default: CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedFailureReasonErrorKey: "\(refusal)"])
                }
            })
        }
    }

    // NSDocument would revert an unedited document; the engine lands the change instead.
    override nonisolated func presentedItemDidChange() {
        Task { @MainActor in live?.signal() }
    }

    override nonisolated func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        Task { @MainActor in live?.moved(to: newURL) }
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        // canAsynchronouslyWrite is false, so AppKit writes on the main thread.
        try MainActor.assumeIsolated {
            let shown = shownText
            let bytes = bytes(of: shown)
            let target = Self.identity(of: url)
            guard saveOperation == .saveOperation || target != nil && target == fileURL.flatMap(Self.identity) else {
                try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
                if saveOperation == .saveAsOperation {
                    (text, baseHash) = (shown, contentHash(bytes))
                }
                return
            }
            do throws(SaveFailure) {
                baseHash = try saveFile(bytes, to: url, base: baseHash)
                text = shown
            } catch .conflict {
                throw SaveConflict(document: self, name: url.lastPathComponent)
            } catch .io(let reason) {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedFailureReasonErrorKey: reason])
            }
        }
    }

    /// The device and inode of the file at `url`, the same for every name of one file.
    private static func identity(of url: URL) -> [Int]? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard let device = attributes?[.systemNumber] as? Int, let inode = attributes?[.systemFileNumber] as? Int else { return nil }
        return [device, inode]
    }

    override func willPresentError(_ error: any Error) -> any Error {
        // NSDocument presents a failed save as "could not be saved"; a conflict says what happened instead.
        error as? SaveConflict ?? (error as NSError).userInfo[NSUnderlyingErrorKey] as? SaveConflict ?? super.willPresentError(error)
    }

    override func makeWindowControllers() {
        // A file inside the folder of the window in front opens there: in place of its empty page, else in a new tab.
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? MainWindowController }.first
        guard let front, let folder = front.folder, fileURL.map({ folder.relativePath(of: $0) != nil }) ?? true else {
            MainWindowController(folder: nil).display(self)
            return
        }
        (front.document == nil ? front : MainWindowController(folder: folder)).display(self)
    }

    override func showWindows() {
        super.showWindows()
        if ProcessInfo.processInfo.environment["DEWLINE_CARET_PROBE"] != nil {
            (windowControllers.first as? MainWindowController)?.textView?.probe()
        }
        // scripts/perf.sh: print milliseconds from process start to this first display, then quit.
        guard ProcessInfo.processInfo.environment["DEWLINE_LAUNCH_PROBE"] != nil else { return }
        windowControllers[0].window!.displayIfNeeded()
        CATransaction.flush()
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&name, 4, &process, &size, nil, 0)
        let start = process.kp_proc.p_starttime
        Swift.print(String(format: "%.1f", Date().timeIntervalSince1970 * 1000 - Double(start.tv_sec) * 1000 - Double(start.tv_usec) / 1000))
        exit(0)
    }
}

/// A save that found the file changed on disk since it was opened or last saved, so it wrote nothing.
struct SaveConflict: LocalizedError, RecoverableError {
    let document: MarkdownDocument
    let name: String

    var errorDescription: String? {
        "“\(name)” changed on disk after you opened it."
    }

    var recoverySuggestion: String? {
        "Your edits are still in this window. Saving now would overwrite that change, so Dewline didn’t save."
    }

    var recoveryOptions: [String] {
        ["Save As…", "Cancel"]
    }

    func attemptRecovery(optionIndex: Int) -> Bool {
        if optionIndex == 0 {
            // After the alert is gone: the save panel is a sheet on the same window.
            Task { @MainActor in document.saveAs(nil) }
        }
        return false
    }
}
