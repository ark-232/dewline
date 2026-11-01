import AppKit
import MdCore

/// The Share sheet: copy a one-time invite link, let people in or not, and remove anyone.
final class ShareSheet: NSViewController {
    private let collaboration: Collaboration
    private let note = NSTextField(wrappingLabelWithString: "Each link lets one person ask to join. You approve them by name.")
    private let pending = NSStackView()
    private let peers = NSStackView()

    init(_ collaboration: Collaboration) {
        self.collaboration = collaboration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ShareSheet is built in code")
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Share “\(collaboration.share.fileName)”")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        note.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy Invite Link", target: self, action: #selector(copyLink(_:)))
        let stop = NSButton(title: "Stop Sharing", target: self, action: #selector(stopSharing(_:)))
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [stop, NSView(), done])
        for list in [pending, peers] {
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 6
        }
        let stack = NSStackView(views: [title, note, copy, pending, peers, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 380),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        self.view = view
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: Collaboration.changed, object: collaboration)
        rebuild()
    }

    private func row(_ name: String, _ actions: [(String, Selector)], peer: String) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.lineBreakMode = .byTruncatingTail
        let buttons = actions.map { title, action in
            let button = NSButton(title: title, target: self, action: action)
            button.identifier = NSUserInterfaceItemIdentifier(peer)
            button.controlSize = .small
            return button
        }
        let row = NSStackView(views: [label] + buttons)
        row.spacing = 8
        return row
    }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func rebuild() {
        let share = collaboration.share
        let waiting = share.pending
        pending.setViews(
            waiting.isEmpty ? [] : [header("Asking to join")] + waiting.map { row($0.name, [("Approve", #selector(approve(_:))), ("Deny", #selector(deny(_:)))], peer: $0.id) },
            in: .top)
        let people = share.peers
        peers.setViews(
            people.isEmpty ? [] : [header("Editing with you")] + people.map { row($0.name, [("Remove", #selector(remove(_:)))], peer: $0.id) },
            in: .top)
    }

    @objc private func changed(_ notification: Notification) {
        rebuild()
    }

    @objc private func copyLink(_ sender: Any?) {
        guard let link = collaboration.share.invite() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        note.stringValue = "Copied. The link works once; copy another for the next person."
    }

    @objc private func approve(_ sender: NSButton) {
        sender.identifier.map { collaboration.share.approve($0.rawValue) }
        rebuild()
    }

    @objc private func deny(_ sender: NSButton) {
        sender.identifier.map { collaboration.share.deny($0.rawValue) }
        rebuild()
    }

    @objc private func remove(_ sender: NSButton) {
        sender.identifier.map { collaboration.share.remove($0.rawValue) }
        rebuild()
    }

    @objc private func stopSharing(_ sender: Any?) {
        collaboration.end(saying: nil)
        dismiss(nil)
    }

    @objc private func done(_ sender: Any?) {
        dismiss(nil)
    }
}
