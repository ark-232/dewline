import AppKit
import OSLog
import Security
import Sparkle

/// Sparkle under Dewline's rules. The updater runs only in builds signed with the ArkWerx Developer ID, so debug and
/// unsigned builds never poll the feed, and Sparkle itself refuses to start without the EdDSA public key. No
/// scheduled check runs until the first-run line has appeared in a window; a check the user asks for never waits.
/// Every request carries the user agent `Dewline`, and no Sparkle window opens for a scheduled update.
@MainActor
final class Updates: NSObject, NSMenuItemValidation, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates(defaults: .standard)
    static let lineText = "Dewline checks updates.dewline.dev once a day and downloads updates from GitHub."
    static let lineShownKey = "DewlineUpdateLineShown"

    private let defaults: UserDefaults
    var updater: SPUUpdater?
    private(set) var line: UpdateLine?

    init(defaults: UserDefaults) {
        self.defaults = defaults
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

    /// Starts Sparkle in a Developer ID build, then puts the first-run line on a window already showing.
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
        if let window = NSApp.orderedWindows.first(where: { $0.isVisible && Self.carriesLine($0) }) {
            windowDidShow(window)
        }
    }

    /// The launch window and document windows can carry the first-run line; Settings and panels cannot.
    static func carriesLine(_ window: NSWindow) -> Bool {
        window.windowController is LaunchWindowController || window.windowController is MainWindowController
    }

    /// Puts the first-run line on `window` the first time a launch or document window shows with the updater running.
    func windowDidShow(_ window: NSWindow) {
        guard updater != nil, line == nil, !defaults.bool(forKey: Self.lineShownKey) else { return }
        let line = UpdateLine { [weak self] checksDaily in self?.choose(checksDaily: checksDaily) }
        window.addTitlebarAccessoryViewController(line)
        self.line = line
        defaults.set(true, forKey: Self.lineShownKey)
    }

    private func choose(checksDaily: Bool) {
        updater?.automaticallyChecksForUpdates = checksDaily
        line?.removeFromParent()
        line = nil
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater?.checkForUpdates()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(checkForUpdates(_:)) || updater?.canCheckForUpdates == true
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Sparkle schedules the next check a full interval after a refused one.
        guard updateCheck != .updatesInBackground || defaults.bool(forKey: Self.lineShownKey) else {
            throw NSError(domain: "dev.arkwerx.dewline.updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Scheduled update checks wait until the first-run line has appeared.",
            ])
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's window opens only from a click, never for a scheduled update.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }
}

/// The first-run line under the title bar: what the updater sends and where, with Check daily and Don't check.
final class UpdateLine: NSTitlebarAccessoryViewController {
    private let choose: (Bool) -> Void
    let checkDaily = NSButton(title: "Check daily", target: nil, action: nil)
    let dontCheck = NSButton(title: "Don\u{2019}t check", target: nil, action: nil)

    init(choose: @escaping (Bool) -> Void) {
        self.choose = choose
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        let label = NSTextField(labelWithString: Updates.lineText)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(checkDaily, #selector(daily)), (dontCheck, #selector(never))] {
            button.target = self
            button.action = action
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let row = NSStackView(views: [label, checkDaily, dontCheck])
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

    @objc private func daily() {
        choose(true)
    }

    @objc private func never() {
        choose(false)
    }
}
