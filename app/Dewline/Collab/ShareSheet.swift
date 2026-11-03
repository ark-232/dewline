import AppKit
import MdCore

/// Share: copy a one-time invite link, let people in or not, and remove anyone. Shown from the toolbar as a popover,
/// where nothing is shared until Copy Invite Link, or as a sheet over a share already started.
final class ShareSheet: NSViewController {
    /// Where Copy Invite Link puts the link; tests use a pasteboard of their own.
    static var pasteboard = NSPasteboard.general

    private weak var document: MarkdownDocument?
    private(set) var collaboration: Collaboration?
    private let isSheet: Bool
    private let note = NSTextField(wrappingLabelWithString: "Each link lets one person ask to join. You approve them by name.")
    private let pending = NSStackView()
    private let peers = NSStackView()
    private let stop = NSButton()

    /// The popover: shares `document` once a link is copied.
    init(document: MarkdownDocument) {
        self.document = document
        collaboration = Collaboration.of(document)
        isSheet = false
        super.init(nibName: nil, bundle: nil)
    }

    /// The sheet over a share already started.
    init(_ collaboration: Collaboration) {
        self.collaboration = collaboration
        document = collaboration.document as? MarkdownDocument
        isSheet = true
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ShareSheet is built in code")
    }

    override func loadView() {
        let name = document.map { ($0.displayName as NSString).deletingPathExtension } ?? collaboration?.share.fileName ?? "this note"
        let title = NSTextField(labelWithString: "Share “\(name)” to edit together")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        note.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy Invite Link", target: self, action: #selector(copyLink(_:)))
        copy.keyEquivalent = "\r"
        stop.title = "Stop Sharing"
        stop.bezelStyle = .push
        stop.target = self
        stop.action = #selector(stopSharing(_:))
        var bottom: [NSView] = [stop, NSView()]
        if isSheet {
            bottom.append(NSButton(title: "Done", target: self, action: #selector(done(_:))))
        }
        let buttons = NSStackView(views: bottom)
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
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: Collaboration.changed, object: nil)
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
        let share = collaboration?.share
        let waiting = share?.pending ?? []
        pending.setViews(
            waiting.isEmpty ? [] : [header("Asking to join")] + waiting.map { row($0.name, [("Approve", #selector(approve(_:))), ("Deny", #selector(deny(_:)))], peer: $0.id) },
            in: .top)
        let people = share?.peers ?? []
        peers.setViews(
            people.isEmpty ? [] : [header("Editing with you")] + people.map { row($0.name, [("Remove", #selector(remove(_:)))], peer: $0.id) },
            in: .top)
        stop.isHidden = collaboration == nil
    }

    @objc private func changed(_ notification: Notification) {
        // A share that ended is gone; one this popover's note started since is picked up.
        if let document { collaboration = Collaboration.of(document) }
        rebuild()
    }

    /// Starts sharing on the first copy, then copies a new one-time link.
    @objc func copyLink(_ sender: Any?) {
        guard let collaboration = collaboration ?? start(), let link = collaboration.share.invite() else { return }
        Self.pasteboard.clearContents()
        Self.pasteboard.setString(link, forType: .string)
        note.stringValue = "Link copied. It works for one person."
        rebuild()
    }

    private func start() -> Collaboration? {
        guard let document, let textView = document.textView else { return nil }
        do {
            collaboration = try Collaboration.host(document, textView: textView)
        } catch {
            note.stringValue = "Dewline couldn’t start sharing. \(error.message)"
        }
        return collaboration
    }

    @objc private func approve(_ sender: NSButton) {
        sender.identifier.map { collaboration?.share.approve($0.rawValue) }
        rebuild()
    }

    @objc private func deny(_ sender: NSButton) {
        sender.identifier.map { collaboration?.share.deny($0.rawValue) }
        rebuild()
    }

    @objc private func remove(_ sender: NSButton) {
        sender.identifier.map { collaboration?.share.remove($0.rawValue) }
        rebuild()
    }

    @objc private func stopSharing(_ sender: Any?) {
        collaboration?.end(saying: nil)
        collaboration = nil
        dismiss(nil)
    }

    @objc private func done(_ sender: Any?) {
        dismiss(nil)
    }
}
