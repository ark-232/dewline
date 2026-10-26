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

@MainActor
struct UpdatesTests {
    private let suite = "dev.arkwerx.dewline.tests.updates"

    @Test func theAppAsksSparkleForASignedHTTPSFeedAndSendsNothingElse() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://updates.dewline.dev/appcast.xml")
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
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let updates = Updates(defaults: defaults)
        let first = window()
        updates.windowDidShow(first)
        #expect(first.titlebarAccessoryViewControllers.isEmpty, "no line without a running updater")

        updates.updater = fixture.updater()
        updates.windowDidShow(first)
        let line = try #require(first.titlebarAccessoryViewControllers.first as? UpdateLine)
        #expect(defaults.bool(forKey: Updates.lineShownKey))
        let texts = line.view.subviews.flatMap(\.subviews).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(texts == ["Dewline checks updates.dewline.dev once a day and downloads updates from GitHub."])
        #expect(line.checkDaily.title == "Check daily" && line.dontCheck.title == "Don\u{2019}t check")

        let second = window()
        updates.windowDidShow(second)
        #expect(second.titlebarAccessoryViewControllers.isEmpty)

        line.dontCheck.performClick(nil)
        #expect(first.titlebarAccessoryViewControllers.isEmpty)
        #expect(updates.updater?.automaticallyChecksForUpdates == false)

        let relaunched = Updates(defaults: defaults)
        relaunched.updater = fixture.updater()
        relaunched.windowDidShow(second)
        #expect(second.titlebarAccessoryViewControllers.isEmpty, "the line shows on first run only")
    }
}
