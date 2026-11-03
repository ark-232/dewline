import AppKit
import MdCore
import Testing
@testable import Dewline

/// Two Collaborations in one test host, over 127.0.0.1 with no relay: a host's note opened through the change engine
/// and a guest's copy, in windows that are never shown.
@MainActor
@Suite(.serialized)
struct CollaborationTests {
    private static let type = "net.daringfireball.markdown"

    /// The host shares from the popover, which starts nothing until Copy Invite Link. The guest waits with a line
    /// that names the host; the host sees the request and approves it; then each one's typing reaches the other, and
    /// the host's engine saves the guest's text to the file.
    @Test func aGuestWaitsIsLetInAndBothEditTheNote() async throws {
        let root = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().appending(path: "dewline-collab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appending(path: "notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let url = notes.appending(path: "plan.md")
        try Data("Ship on Friday.\n".utf8).write(to: url)
        let engine = try ChangeEngine(store: root.appending(path: "store"))

        let preferences = Preferences.shared
        let (name, folder) = (preferences.collaborationName, preferences.sharedFolder)
        preferences.collaborationName = "Rick"
        preferences.sharedFolder = root.appending(path: "shared", directoryHint: .isDirectory)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dewline.tests.\(UUID().uuidString)"))
        (Collaboration.loopback, Collaboration.showsWindows, ShareSheet.pasteboard) = (true, false, pasteboard)
        // Two Macs: a node key each, and none in the Keychain.
        var kept: [String] = []
        (Collaboration.nodeKey, Collaboration.keepKey) = (Share.newNodeKey, { _, account in kept.append(account) })
        defer {
            (preferences.collaborationName, preferences.sharedFolder) = (name, folder)
            (Collaboration.loopback, Collaboration.showsWindows, ShareSheet.pasteboard) = (false, true, .general)
            (Collaboration.nodeKey, Collaboration.keepKey) = (SyncKeychain.nodeKey, SyncKeychain.write)
            pasteboard.releaseGlobally()
        }

        let document = MarkdownDocument()
        document.engine = engine
        try document.read(from: url, ofType: Self.type)
        document.makeWindowControllers()
        defer { document.close() }
        let hostText = try #require(document.textView)

        // The popover shares nothing until the link is copied.
        let popover = Collaboration.sharePopover(for: document) as! ShareSheet
        _ = popover.view
        #expect(Collaboration.of(document) == nil)
        popover.copyLink(nil)
        let host = try #require(Collaboration.of(document))
        let invite = try #require(pasteboard.string(forType: .string))
        #expect(invite.contains("addr=127.0.0.1") && invite.contains("name=Rick"))

        let guest = try Collaboration.join(link: invite, name: "Ana")
        defer { guest.end(saying: nil) }
        try await Self.until { guest.share.status == .waiting }
        #expect(guest.waitingText == "Waiting for Rick to let you in.")
        try await Self.until { host.share.pending.map(\.name) == ["Ana"] }
        #expect(Collaboration.asking.map(\.peer.name) == ["Ana"])

        let request = try #require(host.share.pending.first)
        host.share.approve(request.id)
        try await Self.until { guest.document != nil }
        #expect(guest.waitingText == nil)
        #expect(host.share.peers.map(\.name) == ["Ana"])
        let guestDocument = try #require(guest.document as? MarkdownDocument)
        defer { guestDocument.close() }
        let guestText = try #require(guestDocument.textView)
        #expect(guestText.string == "Ship on Friday.\n")
        #expect(guestDocument.fileURL?.deletingLastPathComponent().lastPathComponent == "shared")

        // The guest types; the host's buffer takes it and the engine saves it to the host's file.
        guestText.insertText("Monday", replacementRange: (guestText.string as NSString).range(of: "Friday"))
        try await Self.until { hostText.string == "Ship on Monday.\n" }
        try await Self.until(within: .seconds(6)) { (try? String(contentsOf: url, encoding: .utf8)) == "Ship on Monday.\n" }

        // The host types; the guest's buffer takes it.
        hostText.setSelectedRange(NSRange(location: 0, length: 0))
        hostText.insertText("Plan: ", replacementRange: hostText.selectedRange())
        try await Self.until { guestText.string == "Plan: Ship on Monday.\n" }
        try await Self.until(within: .seconds(6)) { (try? String(contentsOf: url, encoding: .utf8)) == "Plan: Ship on Monday.\n" }
        #expect(hostText.window?.isVisible == false && guestText.window?.isVisible == false)
        guest.end(saying: nil)
        host.end(saying: nil)
        #expect(Collaboration.of(document) == nil)
        #expect(kept.allSatisfy { $0.hasPrefix("document ") } && !kept.isEmpty)
    }

    private static func until(within limit: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
