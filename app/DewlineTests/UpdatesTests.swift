import AppKit
import Sparkle
import Testing
@testable import Dewline

/// A bundle on disk carrying the built app's Sparkle keys. Sparkle keeps a bundle's settings under that bundle's
/// identifier, so an updater aimed here never touches the app's own defaults; scheduled checks are off, so nothing
/// sends a request.
@MainActor
private struct Fixture {
    static let identifier = "dev.arkwerx.dewline.tests.updater"
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let bundle: Bundle

    init(publicKey: String) throws {
        let contents = folder.appending(path: "Fixture.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = (Bundle.main.infoDictionary ?? [:]).filter { $0.key.hasPrefix("SU") }
        info.merge([
            "CFBundleIdentifier": Self.identifier, "CFBundleName": "Fixture", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "SUPublicEDKey": publicKey, "SUEnableAutomaticChecks": false,
        ]) { $1 }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        bundle = try #require(Bundle(url: folder.appending(path: "Fixture.app")))
    }

    func updater() -> SPUUpdater {
        SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removePersistentDomain(forName: Self.identifier)
    }
}

/// A titled window that is never shown.
@MainActor
private func window() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
}

/// The sentence of each update line on `window`.
@MainActor
private func lines(_ window: NSWindow) -> [String] {
    window.titlebarAccessoryViewControllers.compactMap { $0 as? UpdateLine }
        .flatMap { $0.view.subviews.flatMap(\.subviews).compactMap { ($0 as? NSTextField)?.stringValue } }
}

@MainActor
struct UpdatesTests {
    private let suite = "dev.arkwerx.dewline.tests.updates"

    @Test func theAppAsksSparkleForASignedHTTPSFeedAndSendsNothingElse() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://dewline.arkwerx.com/appcast.xml")
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info["SUEnableJavaScript"] as? Bool == false)
        #expect(info["SUPublicEDKey"] is String)
    }

    @Test func debugAndUnsignedBuildsNeverStartTheUpdater() {
        #expect(!Updates.isDeveloperIDSigned)
        #expect(Updates.shared.updater == nil)
    }

    /// The built app's keys with its EdDSA key, which is empty until the owner makes one, refuse to start, and an
    /// updater that never started cannot check, download or install. A well-formed key starts the same configuration.
    @Test func theUpdaterStartsOnlyWithAnEdDSAKey() async throws {
        let built = try #require(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        let wellFormed = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        for key in Set([built, "", wellFormed]) {
            let fixture = try Fixture(publicKey: key)
            defer { fixture.remove() }
            let updater = fixture.updater()
            if key.isEmpty {
                let error = #expect(throws: (any Error).self) { try updater.start() }
                #expect(error?.localizedDescription == "The EdDSA public key is not valid for Fixture.")
                #expect(!updater.canCheckForUpdates)
            } else {
                try updater.start()
                #expect(updater.canCheckForUpdates)
                // Sparkle finishes starting on the next turn of the main queue; let it, then clean up.
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    @Test func scheduledChecksWaitForTheLineAndChecksTheUserAsksForNeverWait() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try Fixture(publicKey: "")
        defer { fixture.remove() }
        let updates = Updates(defaults: defaults)
        let updater = fixture.updater()
        #expect(throws: (any Error).self) { try updates.updater(updater, mayPerform: .updatesInBackground) }
        try updates.updater(updater, mayPerform: .updates)
        try updates.updater(updater, mayPerform: .updateInformation)
        defaults.set(true, forKey: Updates.lineShownKey)
        try updates.updater(updater, mayPerform: .updatesInBackground)
    }

    @Test func theLineShowsOnceOnTheFirstWindowAndDontCheckTurnsChecksOff() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try Fixture(publicKey: "")
        defer { fixture.remove() }
        let updates = Updates(defaults: defaults)
        let first = window()
        updates.windowDidShow(first)
        #expect(first.titlebarAccessoryViewControllers.isEmpty, "no line without a running updater")

        updates.updater = fixture.updater()
        updates.windowDidShow(first)
        let line = try #require(first.titlebarAccessoryViewControllers.first as? UpdateLine)
        #expect(defaults.bool(forKey: Updates.lineShownKey))
        let texts = line.view.subviews.flatMap(\.subviews).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts == ["Dewline checks GitHub for updates once a day and downloads them from there."])
        #expect(line.buttons.map(\.title) == ["Check daily", "Don\u{2019}t check"])

        let second = window()
        updates.windowDidShow(second)
        #expect(second.titlebarAccessoryViewControllers.isEmpty)

        line.buttons[1].performClick(nil)
        #expect(first.titlebarAccessoryViewControllers.isEmpty)
        #expect(updates.updater?.automaticallyChecksForUpdates == false)
        #expect(!updates.automaticChecks)
        updates.setAutomaticChecks(true)
        #expect(updates.updater?.automaticallyChecksForUpdates == true, "Settings > Updates turns checks back on")

        let relaunched = Updates(defaults: defaults)
        relaunched.updater = fixture.updater()
        relaunched.windowDidShow(second)
        #expect(second.titlebarAccessoryViewControllers.isEmpty, "the line shows on first run only")
    }

    @Test func aStagedUpdateRenamesTheMenuItemAndKeepsTheDateItFirstStaged() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let updates = Updates(defaults: defaults)
        updates.now = { start }
        let item = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "")
        _ = updates.validateMenuItem(item)
        #expect(item.title == "Check for Updates\u{2026}")
        #expect(updates.stagedText == nil)

        updates.stage(version: "1.4.0", critical: false) {}
        #expect(updates.validateMenuItem(item))
        #expect(item.title == "Restart to Update to 1.4.0")
        #expect(updates.stagedText == "1.4.0 is ready and installs when you quit.")

        let relaunched = Updates(defaults: defaults)
        relaunched.now = { start.addingTimeInterval(3 * 86400) }
        relaunched.stage(version: "1.4.0", critical: false) {}
        #expect(relaunched.staged?.date == start, "a relaunch without an install keeps the count")
        relaunched.stage(version: "1.4.1", critical: false) {}
        #expect(relaunched.staged?.date == start.addingTimeInterval(3 * 86400), "a new version starts it again")
    }

    @Test func restartRunsTheKeptBlockOnceNoCompositionIsOpen() async throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = Updates(defaults: defaults)
        var installs = 0
        updates.stage(version: "1.4.0", critical: false) { installs += 1 }
        updates.checkForUpdates(nil)
        #expect(installs == 1, "with no composition the menu item installs at once")

        final class Composition { var open = true }
        let composition = Composition()
        updates.composing = { composition.open }
        updates.restart()
        #expect(installs == 1, "an open IME composition holds the restart")
        composition.open = false
        let storage = NSTextStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\u{304B}")
        // The check runs a turn after the edit.
        try await Task.sleep(for: .milliseconds(100))
        #expect(installs == 2)
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        try await Task.sleep(for: .milliseconds(100))
        #expect(installs == 2, "the wait ends with the composition")
    }

    @Test func theReadyLineWaitsSevenDaysUnlessTheUpdateIsCritical() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Updates.lineShownKey)
        let fixture = try Fixture(publicKey: "")
        defer { fixture.remove() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        let updates = Updates(defaults: defaults)
        updates.updater = fixture.updater()
        updates.now = { clock }
        let first = window()
        updates.windows = { [first] }

        updates.stage(version: "1.4.0", critical: false) {}
        #expect(lines(first).isEmpty, "staged, nothing on screen changes")
        clock = start.addingTimeInterval(6 * 86400)
        updates.refresh()
        #expect(lines(first).isEmpty)
        clock = start.addingTimeInterval(7 * 86400)
        updates.refresh()
        #expect(lines(first) == ["1.4.0 is ready."])
        let line = try #require(first.titlebarAccessoryViewControllers.first as? UpdateLine)
        #expect(line.buttons.map(\.title) == ["Restart"])
        updates.refresh()
        #expect(first.titlebarAccessoryViewControllers.count == 1, "one line a window, however often the app activates")

        let later = window()
        updates.windowDidShow(later)
        #expect(lines(later) == ["1.4.0 is ready."], "a window that shows later carries it too")

        let critical = Updates(defaults: defaults)
        critical.now = { clock }
        let other = window()
        critical.windows = { [other] }
        critical.stage(version: "1.4.1", critical: true) {}
        #expect(lines(other) == ["1.4.1 is ready."], "a critical update says so at once")
    }

    @Test func anUpdateThatNeedsAPasswordSaysSoOnEveryWindowAndOnlyAClickOpensSparkle() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = Updates(defaults: defaults)
        let windows = [window(), window()]
        updates.windows = { windows }

        updates.updateWillShow(version: "1.4.0", handledBySparkle: true, userInitiated: true)
        #expect(windows.allSatisfy { lines($0).isEmpty }, "a check the user started shows Sparkle's own window")
        updates.updateWillShow(version: "1.4.0", handledBySparkle: false, userInitiated: false)
        for shown in windows {
            #expect(lines(shown) == ["1.4.0 needs your password to install."])
            let line = try #require(shown.titlebarAccessoryViewControllers.first as? UpdateLine)
            #expect(line.buttons.map(\.title) == ["Install\u{2026}"])
            #expect(line.buttons[0].target === line && line.buttons[0].action != nil)
        }
        updates.standardUserDriverWillFinishUpdateSession()
        #expect(windows.allSatisfy { lines($0).isEmpty })
    }

    @Test func settingsShowsTheErrorsOfChecksThatRanAndNotOfOnesDewlineRefused() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try Fixture(publicKey: "")
        defer { fixture.remove() }
        let updater = fixture.updater()
        let updates = Updates(defaults: defaults)
        let refusal = #expect(throws: (any Error).self) { try updates.updater(updater, mayPerform: .updatesInBackground) }
        updates.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: refusal)
        #expect(updates.lastError == nil, "a refused check sent no request")

        updates.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        #expect(updates.lastError != nil)
        updates.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        #expect(updates.lastError == nil, "no update is not an error")
    }

    @Test func getBetaBuildsAddsTheBetaChannel() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try Fixture(publicKey: "")
        defer { fixture.remove() }
        let updater = fixture.updater()
        let updates = Updates(defaults: defaults)
        #expect(updates.allowedChannels(for: updater).isEmpty)
        updates.setBeta(true)
        #expect(updates.allowedChannels(for: updater) == ["beta"])
        #expect(Updates(defaults: defaults).allowedChannels(for: updater) == ["beta"], "the choice persists")
        updates.setBeta(false)
        #expect(updates.allowedChannels(for: updater).isEmpty)
    }

    @Test func whatsNewShowsOnceAfterAnUpdateWhoseVersionHasNotes() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: Updates.lineShownKey)
        let fixture = try Fixture(publicKey: "")
        defer { fixture.remove() }
        let changelog = "# Changelog\n\n## 1.4.0 (2 Nov 2026)\n\n### New\n- Review Changes.\n\n## 1.3.2\n\n### Fixed\n- A crash.\n"
        func launch(build: Int, version: String) -> (Updates, NSWindow) {
            let updates = Updates(defaults: defaults)
            updates.updater = fixture.updater()
            updates.noteLaunch(build: build, version: version, changelog: changelog)
            let shown = window()
            updates.windowDidShow(shown)
            return (updates, shown)
        }
        #expect(lines(launch(build: 1200, version: "1.3.2").1).isEmpty, "a first install shows nothing")

        let (updates, updated) = launch(build: 1234, version: "1.4.0")
        #expect(lines(updated) == ["Updated to 1.4.0."])
        let line = try #require(updated.titlebarAccessoryViewControllers.first as? UpdateLine)
        #expect(line.buttons.map(\.title) == ["What changed"])
        let second = window()
        updates.windowDidShow(second)
        #expect(lines(second).isEmpty, "one window carries it")
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        updates.whatsNewSaw(key)
        #expect(lines(updated).isEmpty, "the first keystroke takes it away")

        #expect(lines(launch(build: 1234, version: "1.4.0").1).isEmpty, "the next launch shows nothing")
        #expect(lines(launch(build: 1240, version: "1.4.1").1).isEmpty, "a version with no section shows nothing")
    }

    @Test func theNotesAreTheVersionsSectionOfTheChangelog() {
        let changelog = """
            # Changelog

            ## 1.4.1 (critical)

            ### Fixed
            - Saving no longer drops the last line.

            ## 1.4.0 (2 Nov 2026)

            ### New
            - Review Changes lists every outside change.

            ## 1.4.0-beta.1

            ### New
            - Review Changes, first cut.
            """
        #expect(Updates.notes(for: "1.4.0", in: changelog) == "## 1.4.0 (2 Nov 2026)\n\n### New\n- Review Changes lists every outside change.")
        #expect(Updates.notes(for: "1.4.1", in: changelog) == "## 1.4.1 (critical)\n\n### Fixed\n- Saving no longer drops the last line.")
        #expect(Updates.notes(for: "1.4.0-beta.1", in: changelog) == "## 1.4.0-beta.1\n\n### New\n- Review Changes, first cut.")
        #expect(Updates.notes(for: "1.4", in: changelog) == nil)
        #expect(Updates.notes(for: "1.3.0", in: changelog) == nil)
    }
}
