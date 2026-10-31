import AppKit
import Observation
import OSLog
import Security
import Sparkle

/// Sparkle under Dewline's rules. The updater runs only in builds signed with the ArkWerx Developer ID, so debug and
/// unsigned builds never poll the feed, and Sparkle itself refuses to start without the EdDSA public key. No
/// scheduled check runs until the first-run line has appeared in a window; a check the user asks for never waits.
/// Every request carries the user agent `Dewline`. An update downloads in the background and installs when the app
/// quits; the app restarts only from a click, and no Sparkle window opens without one.
@MainActor
@Observable
final class Updates: NSObject, NSMenuItemValidation, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates(defaults: .standard)
    static let lineText = "Dewline checks GitHub for updates once a day and downloads them from there."
    static let lineShownKey = "DewlineUpdateLineShown"
    static let betaKey = "DewlineBetaUpdates"
    static let stagedVersionKey = "DewlineUpdateStagedVersion"
    static let stagedDateKey = "DewlineUpdateStagedDate"
    static let lastBuildKey = "DewlineLastBuild"
    /// The error domain of a scheduled check refused before the first-run line, which sends no request.
    static let refusalDomain = "dev.arkwerx.dewline.updates"
    /// How long a staged update waits for a quit before every window says it is ready.
    static let patience: TimeInterval = 7 * 24 * 60 * 60

    /// An update Sparkle downloaded and verified. It installs when the app quits, or at once through `install`.
    struct Staged {
        let version: String
        let critical: Bool
        /// When this version was first staged, kept across launches.
        let date: Date
        let install: () -> Void
    }

    /// The version this launch was updated to, with its changelog section.
    struct WhatsNew {
        let version: String
        let notes: String
    }

    /// What every launch and document window says about a downloaded update.
    enum Attention: Equatable {
        /// "1.4.0 is ready. Restart", after 7 days without a quit, or at once for a critical update.
        case ready(String)
        /// "1.4.0 needs your password to install. Install…", when Sparkle cannot install it alone.
        case password(String)
        /// A restart that waits until the files a tool waits on (`dewline open --wait`) close.
        case waiting(String, files: [String])
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var now: () -> Date = { Date() }
    /// The launch and document windows, tabs included.
    @ObservationIgnored var windows: @MainActor () -> [NSWindow] = { NSApp.windows.filter { Updates.carriesLine($0) } }
    /// Whether the key window holds an open IME composition.
    @ObservationIgnored var composing: @MainActor () -> Bool = { (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true }
    /// The open documents a `dewline open --wait` client is waiting on.
    @ObservationIgnored var awaited: @MainActor () -> [MarkdownDocument] = {
        NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.filter(\.isAwaited)
    }

    var updater: SPUUpdater?
    private(set) var automaticChecks = false
    private(set) var beta: Bool
    private(set) var lastCheck: Date?
    private(set) var lastError: String?
    private(set) var staged: Staged?
    /// Settings > Updates' line while an update is staged.
    var stagedText: String? { staged.map { "\($0.version) is ready and installs when you quit." } }
    @ObservationIgnored private(set) var line: UpdateLine?
    @ObservationIgnored private var attention: Attention?
    @ObservationIgnored private var attentionLines: [UpdateLine] = []
    /// What's New waiting for the first launch or document window.
    @ObservationIgnored private var whatsNew: WhatsNew?
    @ObservationIgnored private var whatsNewLine: UpdateLine?
    @ObservationIgnored private var whatsNewMonitor: Any?
    @ObservationIgnored private var afterComposition: (() -> Void)?
    @ObservationIgnored private var compositionObserver: (any NSObjectProtocol)?
    /// A restart waiting for tools, with the version it restarts into.
    @ObservationIgnored private var afterTools: (version: String, work: () -> Void)?
    @ObservationIgnored private var toolObservers: [any NSObjectProtocol] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        beta = defaults.bool(forKey: Self.betaKey)
    }

    /// True when this process carries the ArkWerx Developer ID signature, which only release builds have.
    static let isDeveloperIDSigned: Bool = {
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"7W6LLR2DK7\""
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }()

    /// Starts Sparkle in a Developer ID build, notes the build for What's New, then puts the lines that are due on a
    /// window already showing.
    func start() {
        guard Self.isDeveloperIDSigned else { return }
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: self), delegate: self)
        updater.userAgentString = "Dewline"
        do {
            try updater.start()
        } catch {
            Logger(subsystem: "dev.arkwerx.dewline", category: "updates")
                .error("The updater did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.updater = updater
        automaticChecks = updater.automaticallyChecksForUpdates
        lastCheck = updater.lastUpdateCheckDate
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let changelog = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        noteLaunch(build: build, version: version, changelog: changelog ?? "")
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        if let window = NSApp.orderedWindows.first(where: { $0.isVisible && Self.carriesLine($0) }) {
            windowDidShow(window)
        }
    }

    /// The launch window and document windows can carry the update lines; Settings and panels cannot.
    static func carriesLine(_ window: NSWindow) -> Bool {
        window.windowController is LaunchWindowController || window.windowController is MainWindowController
    }

    /// Puts the lines that are due on `window` when a launch or document window shows with the updater running: the
    /// first-run line and What's New on the first such window, the update line on every one.
    func windowDidShow(_ window: NSWindow) {
        guard updater != nil else { return }
        if line == nil, !defaults.bool(forKey: Self.lineShownKey) {
            let line = UpdateLine(Self.lineText, buttons: [
                ("Check daily", { [weak self] in self?.choose(checksDaily: true) }),
                ("Don\u{2019}t check", { [weak self] in self?.choose(checksDaily: false) }),
            ])
            window.addTitlebarAccessoryViewController(line)
            self.line = line
            defaults.set(true, forKey: Self.lineShownKey)
        }
        if let whatsNew {
            self.whatsNew = nil
            showWhatsNew(whatsNew, on: window)
        }
        if let attention {
            addLine(attention, to: window)
        }
    }

    private func choose(checksDaily: Bool) {
        setAutomaticChecks(checksDaily)
        line?.removeFromParent()
        line = nil
    }

    func setAutomaticChecks(_ on: Bool) {
        automaticChecks = on
        updater?.automaticallyChecksForUpdates = on
    }

    func setBeta(_ on: Bool) {
        beta = on
        defaults.set(on, forKey: Self.betaKey)
    }

    /// Settings > Updates > Check Now. The user asked, so Sparkle's window may open.
    func checkNow() {
        updater?.checkForUpdates()
    }

    /// The app menu item: Check for Updates…, or Restart to Update once an update is staged.
    @objc func checkForUpdates(_ sender: Any?) {
        if staged != nil {
            restart()
        } else {
            updater?.checkForUpdates()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(checkForUpdates(_:)) else { return true }
        item.title = staged.map { "Restart to Update to \($0.version)" } ?? "Check for Updates\u{2026}"
        return staged != nil || updater?.canCheckForUpdates == true
    }

    // MARK: Staged updates

    /// Keeps a staged update's install block for the restart click. The 7-day count starts the first time a version
    /// stages, so a relaunch without an install keeps it.
    func stage(version: String, critical: Bool, install: @escaping () -> Void) {
        let date: Date
        if defaults.string(forKey: Self.stagedVersionKey) == version, let first = defaults.object(forKey: Self.stagedDateKey) as? Date {
            date = first
        } else {
            date = now()
            defaults.set(version, forKey: Self.stagedVersionKey)
            defaults.set(date, forKey: Self.stagedDateKey)
        }
        staged = Staged(version: version, critical: critical, date: date, install: install)
        refresh()
    }

    /// Shows the ready line on every window once the staged update has waited 7 days for a quit, or at once when it
    /// is critical, unless a restart already waits for tools. It runs on each activation and never on a timer.
    func refresh() {
        guard let staged, afterTools == nil, staged.critical || now().timeIntervalSince(staged.date) >= Self.patience else { return }
        show(.ready(staged.version))
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        refresh()
    }

    /// Restarts into the staged update once no tool waits on an open file and no IME composition is open. Sparkle
    /// then quits the app through the usual review of unsaved documents, installs and relaunches. A canceled quit
    /// keeps the app and the staged update.
    func restart() {
        guard let staged else { return }
        restart(into: staged.version, then: staged.install)
    }

    private func restart(into version: String, then install: @escaping () -> Void) {
        whenNoToolWaits(into: version) { [weak self] in self?.whenNotComposing(install) }
    }

    /// Runs `work` once no `dewline open --wait` client waits on an open document. Until then every window names the
    /// files, and each document that closes, or a return to the app, checks again. A tool hears that its file
    /// closed, never that the app quit under it.
    private func whenNoToolWaits(into version: String, _ work: @escaping () -> Void) {
        afterTools = (version, work)
        toolsMayHaveFinished()
        guard afterTools != nil, toolObservers.isEmpty else { return }
        for name in [MarkdownDocument.didCloseNotification, NSApplication.didBecomeActiveNotification] {
            toolObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.toolsMayHaveFinished() }
            })
        }
    }

    private func toolsMayHaveFinished() {
        guard let pending = afterTools else { return }
        let files = awaited().compactMap(\.displayName)
        guard files.isEmpty else { return show(.waiting(pending.version, files: files)) }
        toolObservers.forEach { NotificationCenter.default.removeObserver($0) }
        toolObservers = []
        afterTools = nil
        if case .waiting = attention { removeAttentionLines() }
        pending.work()
    }

    private func whenNotComposing(_ work: @escaping () -> Void) {
        guard composing() else { return work() }
        afterComposition = work
        guard compositionObserver == nil else { return }
        compositionObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The text view moves its marked range after the storage edit, so the check waits a turn.
            Task { @MainActor in self?.compositionMayHaveEnded() }
        }
    }

    private func compositionMayHaveEnded() {
        guard !composing(), let observer = compositionObserver, let work = afterComposition else { return }
        NotificationCenter.default.removeObserver(observer)
        compositionObserver = nil
        afterComposition = nil
        work()
    }

    // MARK: Lines on every window

    private func show(_ attention: Attention) {
        if attention != self.attention {
            removeAttentionLines()
            self.attention = attention
        }
        for window in windows() {
            addLine(attention, to: window)
        }
    }

    private func addLine(_ attention: Attention, to window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { line in attentionLines.contains { $0 === line } }) else { return }
        let line: UpdateLine
        switch attention {
        case .ready(let version):
            line = UpdateLine("\(version) is ready.", buttons: [("Restart", { [weak self] in self?.restart() })])
        case .password(let version):
            line = UpdateLine("\(version) needs your password to install.", buttons: [("Install\u{2026}", { [weak self] in self?.checkNow() })])
        case .waiting(let version, let files):
            let waiting = files.count == 1 ? "a tool is" : "tools are"
            line = UpdateLine("Dewline restarts into \(version) when you close \(ListFormatter.localizedString(byJoining: files)), which \(waiting) waiting on.", buttons: [])
        }
        window.addTitlebarAccessoryViewController(line)
        attentionLines.append(line)
    }

    private func removeAttentionLines() {
        attentionLines.forEach { $0.removeFromParent() }
        attentionLines = []
        attention = nil
    }

    /// A scheduled update reaches the user driver only when Sparkle downloaded it but could not install it alone, so
    /// every window says it needs a password. A check the user started shows Sparkle's window instead.
    func updateWillShow(version: String, handledBySparkle: Bool, userInitiated: Bool) {
        guard !handledBySparkle, !userInitiated else { return }
        show(.password(version))
    }

    private func passwordLineIsDone() {
        if case .password = attention { removeAttentionLines() }
    }

    // MARK: What's New

    /// Records the running build. When it is above the build that ran before and the bundled changelog has a section
    /// for this version, the first launch or document window says what it was updated to.
    func noteLaunch(build: Int, version: String, changelog: String) {
        let previous = defaults.integer(forKey: Self.lastBuildKey)
        defaults.set(build, forKey: Self.lastBuildKey)
        guard previous > 0, previous < build, let notes = Self.notes(for: version, in: changelog) else { return }
        whatsNew = WhatsNew(version: version, notes: notes)
    }

    /// The section of `changelog` headed `## <version>`, heading included, up to the next `## ` heading: the rule the
    /// release workflow uses for the appcast and the release body.
    static func notes(for version: String, in changelog: String) -> String? {
        var section: [Substring] = []
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "##" {
                if !section.isEmpty { break }
                if fields.count > 1, fields[1] == version { section.append(line) }
            } else if !section.isEmpty {
                section.append(line)
            }
        }
        return section.isEmpty ? nil : section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showWhatsNew(_ whatsNew: WhatsNew, on window: NSWindow) {
        let line = UpdateLine("Updated to \(whatsNew.version).", buttons: [("What changed", { [weak self] in self?.openWhatChanged(whatsNew) })])
        window.addTitlebarAccessoryViewController(line)
        whatsNewLine = line
        // The line goes at the first keystroke or the first click outside it, and the next launch never shows it.
        whatsNewMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.whatsNewSaw(event) }
            return event
        }
    }

    func whatsNewSaw(_ event: NSEvent) {
        guard let view = whatsNewLine?.view else { return }
        if event.type != .keyDown, event.window === view.window, view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { return }
        dismissWhatsNew()
    }

    private func dismissWhatsNew() {
        whatsNewLine?.removeFromParent()
        whatsNewLine = nil
        if let whatsNewMonitor { NSEvent.removeMonitor(whatsNewMonitor) }
        whatsNewMonitor = nil
    }

    /// Opens the version's changelog section as a read-only tab, drawn by the editor: no web view, no request.
    private func openWhatChanged(_ whatsNew: WhatsNew) {
        dismissWhatsNew()
        let document = MarkdownDocument()
        try! document.read(from: Data(whatsNew.notes.utf8), ofType: "net.daringfireball.markdown")
        document.displayName = "What changed in \(whatsNew.version)"
        NSDocumentController.shared.addDocument(document)
        let tab = MainWindowController(folder: nil)
        tab.display(document)
        tab.textView?.isEditable = false
        tab.showWindow(nil)
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Sparkle schedules the next check a full interval after a refused one.
        guard updateCheck != .updatesInBackground || defaults.bool(forKey: Self.lineShownKey) else {
            throw NSError(domain: Self.refusalDomain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Scheduled update checks wait until the first-run line has appeared.",
            ])
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        beta ? ["beta"] : []
    }

    /// Dewline takes the install block, so Sparkle stops scheduling checks and never presents the update itself; it
    /// still installs the update when the app quits.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        stage(version: item.displayVersionString, critical: item.isCriticalUpdate, install: immediateInstallHandler)
        return true
    }

    /// Sparkle's own Install and Relaunch button waits for tools and an open IME composition the same way.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        restart(into: item.displayVersionString, then: installHandler)
        return true
    }

    /// Keeps the check's time and its error for Settings > Updates; a failed scheduled check shows nothing else. A
    /// check Dewline refused made no request, so it changes neither.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard (error as NSError?)?.domain != Self.refusalDomain else { return }
        lastCheck = updater.lastUpdateCheckDate
        let quiet: [SUError] = [.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError]
        if let error = error as NSError?, error.domain != SUSparkleErrorDomain || !quiet.map({ Int($0.rawValue) }).contains(error.code) {
            lastError = error.localizedDescription
        } else {
            lastError = nil
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's window opens only from a click, never for a scheduled update.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            updateWillShow(version: update.displayVersionString, handledBySparkle: handleShowingUpdate, userInitiated: state.userInitiated)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { passwordLineIsDone() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { passwordLineIsDone() }
    }
}

/// A static line under the title bar: one sentence and the buttons that act on it. Nothing in it moves.
final class UpdateLine: NSTitlebarAccessoryViewController {
    let buttons: [NSButton]
    private let actions: [() -> Void]

    init(_ text: String, buttons: [(String, () -> Void)]) {
        self.buttons = buttons.map { NSButton(title: $0.0, target: nil, action: nil) }
        actions = buttons.map(\.1)
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (index, button) in self.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(clicked(_:))
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.refusesFirstResponder = true
        }
        let row = NSStackView(views: [label] + self.buttons)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        view = background
    }

    required init?(coder: NSCoder) {
        fatalError("UpdateLine is built in code")
    }

    @objc private func clicked(_ sender: NSButton) {
        actions[sender.tag]()
    }
}
