import AppKit
import MdCore

/// File > Snapshots: the front document's snapshots, newest first. Choosing one restores it as one undoable edit;
/// with Option held, each entry pins or unpins it instead.
@MainActor
final class SnapshotsMenu: NSObject, NSMenuDelegate {
    static let shared = SnapshotsMenu()

    private final class Entry {
        weak var live: LiveFile?
        let snapshot: ChangeEngine.Snapshot

        init(_ live: LiveFile, _ snapshot: ChangeEngine.Snapshot) {
            self.live = live
            self.snapshot = snapshot
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        let live = (NSDocumentController.shared.currentDocument as? MarkdownDocument)?.live
        fill(menu, from: live)
        // The list is read off the main thread, so a newer one fills the menu again, open or not.
        live?.reloadSnapshots { [weak self, weak live, weak menu] in
            guard let self, let live, let menu else { return }
            fill(menu, from: live)
        }
    }

    func fill(_ menu: NSMenu, from live: LiveFile?) {
        menu.removeAllItems()
        guard let live, !live.snapshots.isEmpty else {
            menu.addItem(withTitle: "No Snapshots", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for snapshot in live.snapshots {
            let title = "\(Self.time.string(from: snapshot.time)) · \(Self.writer(snapshot.origin))"
            let restore = menu.addItem(withTitle: title, action: #selector(restore(_:)), keyEquivalent: "")
            restore.target = self
            restore.representedObject = Entry(live, snapshot)
            restore.state = snapshot.pinned ? .on : .off
            restore.onStateImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            let pin = menu.addItem(withTitle: "\(snapshot.pinned ? "Unpin" : "Pin") \(title)", action: #selector(pin(_:)), keyEquivalent: "")
            pin.target = self
            pin.representedObject = Entry(live, snapshot)
            pin.keyEquivalentModifierMask = .option
            pin.isAlternate = true
        }
    }

    static func writer(_ origin: ChangeEngine.Origin) -> String {
        switch origin {
        case .user: "You"
        case .agent(.claude, _): "Claude Code"
        case .agent(.codex, _): "Codex"
        case .agent(.cursor, _): "Cursor"
        case .git(let action): action ?? "git"
        case .external: "Unknown app"
        case .collaborator(_, let name): name
        }
    }

    @objc private func restore(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? Entry, let live = entry.live else { return }
        Task { await live.restore(entry.snapshot) }
    }

    @objc private func pin(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? Entry else { return }
        entry.live?.pin(entry.snapshot, !entry.snapshot.pinned)
    }
}
