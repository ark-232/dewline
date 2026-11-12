import AppKit
import MdCore

/// The right pane's Agent tab: a chat with a coding agent the person installed, over the Agent Client Protocol, beside
/// the note. The agent's edits land in the note as marked changes, through AgentWrites.
@MainActor
enum AgentPanel {
    static func makeViewController(window: NSWindow) -> NSViewController {
        AgentPanelController(context: .of(window), window: window)
    }
}

/// What the panel reads from its window, asked at each use since the window's tab can change.
@MainActor
struct AgentContext {
    var folder: @MainActor () -> URL?
    var note: @MainActor () -> URL?
    var selection: @MainActor () -> AgentChat.Selection?
    var documents: @MainActor () -> [MarkdownDocument] = AgentWrites.openDocuments

    static func of(_ window: NSWindow) -> AgentContext {
        let tab: @MainActor () -> MainWindowController? = { [weak window] in window?.windowController as? MainWindowController }
        let note: @MainActor () -> URL? = { (tab()?.document as? MarkdownDocument)?.fileURL }
        return AgentContext(
            folder: { tab()?.folder?.url ?? note()?.deletingLastPathComponent() },
            note: note,
            selection: { tab()?.textView.flatMap(AgentContext.selection) })
    }

    /// The text view's selection with its lines, when it holds any text.
    static func selection(in textView: NSTextView) -> AgentChat.Selection? {
        let range = textView.selectedRange()
        let text = textView.string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let selected = text.substring(with: range)
        guard selected.contains(where: { !$0.isWhitespace }) else { return nil }
        let first = text.substring(to: range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let last = first + selected.trimmingCharacters(in: .newlines).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return AgentChat.Selection(text: selected, lines: first...last)
    }
}

/// The input: Return sends, Shift-Return adds a line, Escape answers a waiting prompt with Don't Allow, Cmd-. stops.
final class AgentInput: NSTextView {
    var send: () -> Void = {}
    var escape: () -> Void = {}
    var stop: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76, flags.isEmpty || flags == .numericPad {
            return send()
        }
        if event.keyCode == 53 { return escape() }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        stop()
    }
}

@MainActor
final class AgentPanelController: NSViewController {
    let context: AgentContext
    var defaults = UserDefaults.standard
    /// Where the agents come from: the login shell's supported ones and Settings' added ones.
    var lookUp: @MainActor (UserDefaults, _ again: Bool) async -> [AgentSpec] = { await AgentDiscovery.look(again: $1, defaults: $0) }
    /// Set Up in a note about unmarked edits.
    var setUpHooks: () -> Void = { NSApp.sendAction(#selector(AppDelegate.setUpHooks(_:)), to: nil, from: nil) }
    private(set) var agents: [AgentSpec] = []
    /// One chat per agent and folder; each ends with the window.
    private var chats: [String: AgentChat] = [:]
    private(set) var chat: AgentChat?
    /// The note whose chip was removed, until another note opens.
    private var noteOff: URL?
    private var selectionOff: AgentChat.Selection?
    private var observers: [any NSObjectProtocol] = []

    let paper = AgentPaper()
    let popup = NSPopUpButton()
    private(set) lazy var newChatButton = AgentLook.button("New Chat", self, #selector(newChat))
    private(set) lazy var stopButton = AgentLook.button("Stop", self, #selector(stopTurn))
    let transcript = NSStackView()
    let scroll = NSScrollView()
    let status = NSStackView()
    let chips = NSStackView()
    let input = AgentInput()
    let inputScroll = NSScrollView()
    private var inputHeight: NSLayoutConstraint!
    let empty = NSStackView()
    private var chatViews: [NSView] = []

    init(context: AgentContext, window: NSWindow?) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
        if let window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endAll() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] note in
            let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                // A hidden panel draws its chips when it shows, so typing in the note does no work here.
                guard let self, sender != ObjectIdentifier(self.input), self.isShown else { return }
                self.updateChips()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: LiveFile.changesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redrawTools() }
        })
    }

    required init?(coder: NSCoder) {
        fatalError("AgentPanelController is built in code")
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for chat in chats.values { chat.end() }
    }

    /// Ends every chat's process: the window is closing.
    func endAll() {
        for chat in chats.values { chat.end() }
        chats = [:]
        chat = nil
    }
}

extension AgentPanelController {
    // MARK: Layout

    private var isShown: Bool {
        isViewLoaded && view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateChips()
    }

    override func loadView() {
        paper.ruleY = 36
        view = paper
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(pickAgent)
        stopButton.isHidden = true
        stopButton.toolTip = "Stop (⌘.)"
        let header = NSStackView(views: [popup, NSView(), stopButton, newChatButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 12
        transcript.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        status.orientation = .vertical
        status.alignment = .leading
        status.spacing = 8
        transcript.addArrangedSubview(status)
        let document = AgentFlipped()
        transcript.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(transcript)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: document.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        chips.orientation = .horizontal
        chips.spacing = 6
        chips.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        input.font = AgentLook.font
        input.textColor = AgentLook.ink
        input.insertionPointColor = AgentLook.ink
        input.drawsBackground = false
        input.isRichText = false
        input.allowsUndo = true
        input.textContainerInset = NSSize(width: 6, height: 6)
        input.isVerticallyResizable = true
        input.autoresizingMask = .width
        input.textContainer?.widthTracksTextView = true
        input.send = { [weak self] in self?.sendTyped() }
        input.escape = { [weak self] in self?.escape() }
        input.stop = { [weak self] in self?.stopTurn() }
        NotificationCenter.default.addObserver(self, selector: #selector(inputChanged), name: NSText.didChangeNotification, object: input)
        inputScroll.documentView = input
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        let inputBox = AgentBox.around(inputScroll, inset: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2), fill: nil, stroke: AgentLook.rule)
        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: Self.height(lines: 3))

        empty.orientation = .vertical
        empty.alignment = .leading
        empty.spacing = 12
        empty.edgeInsets = NSEdgeInsets(top: 24, left: 16, bottom: 16, right: 16)
        empty.isHidden = true

        for view in [header, scroll, chips, inputBox, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            paper.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: paper.topAnchor),
            header.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
            chips.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            chips.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: paper.trailingAnchor),
            inputBox.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 8),
            inputBox.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 12),
            inputBox.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -12),
            inputBox.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -12),
            inputHeight,
            empty.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 1),
            empty.leadingAnchor.constraint(equalTo: paper.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: paper.trailingAnchor),
        ])
        Task { await appear() }
    }

    /// A text height in the input's lines, with its insets.
    static func height(lines: Int) -> CGFloat {
        let font = AgentLook.font
        return ceil(font.ascender - font.descender + font.leading + 1) * CGFloat(lines) + 12
    }

    /// The input grows from 3 lines to 8 as it fills.
    @objc func inputChanged() {
        guard let layout = input.textLayoutManager else { return }
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer.height + 12
        inputHeight.constant = min(max(used, Self.height(lines: 3)), Self.height(lines: 8))
    }

    var inputBox: NSView? { inputScroll.superview }
}

extension AgentPanelController {
    // MARK: Agents and chats

    /// First open: finds the agents, then starts the one last used in this folder. Otherwise it offers the first and
    /// starts nothing until asked, since an agent found on the PATH may not be signed in.
    func appear(again: Bool = false) async {
        agents = await lookUp(defaults, again)
        popup.removeAllItems()
        popup.addItems(withTitles: agents.map(\.name))
        guard !agents.isEmpty else { return showEmpty() }
        let last = context.folder().flatMap { AgentDiscovery.last(in: $0, defaults: defaults) }
        guard let spec = agents.first(where: { $0.name == last }) else {
            chat = nil
            empty.isHidden = true
            for view in [scroll, chips, inputBox] { view?.isHidden = false }
            popup.isHidden = false
            input.isEditable = false
            let name = agents[0].name
            return show(nil, message: "Chat with \(name) about this note. Its edits show up marked in the note.", action: ("Start \(name)", #selector(pickAgent)))
        }
        await use(spec)
    }

    @objc func pickAgent() {
        guard let spec = agents.first(where: { $0.name == popup.titleOfSelectedItem }) else { return }
        Task { await use(spec) }
    }

    /// Shows the agent's chat in the window's folder, starting it if it has none.
    func use(_ spec: AgentSpec, fresh: Bool = false) async {
        guard let folder = context.folder() else {
            return show(nil, message: "Open a folder or a note to chat with an agent about it.")
        }
        popup.selectItem(withTitle: spec.name)
        AgentDiscovery.remember(spec.name, in: folder, defaults: defaults)
        let key = spec.name + "\n" + folder.path
        if fresh { chats.removeValue(forKey: key)?.end() }
        if let existing = chats[key] { return bind(existing) }
        let chat = AgentChat(spec: spec, folder: folder, documents: context.documents)
        chats[key] = chat
        bind(chat)
        await chat.start()
    }

    private func bind(_ chat: AgentChat) {
        self.chat?.itemChanged = { _ in }
        self.chat?.stateChanged = {}
        self.chat = chat
        empty.isHidden = true
        for view in [scroll, chips, inputBox] { view?.isHidden = false }
        popup.isHidden = false
        newChatButton.isHidden = false
        chat.itemChanged = { [weak self, weak chat] index in
            guard let self, let chat, self.chat === chat else { return }
            self.draw(index)
        }
        chat.stateChanged = { [weak self, weak chat] in
            guard let self, let chat, self.chat === chat else { return }
            self.drawState()
        }
        for view in chatViews { view.removeFromSuperview() }
        chatViews = []
        for index in chat.items.indices { draw(index) }
        drawState()
        updateChips()
    }

    @objc func newChat() {
        guard let spec = chat?.spec ?? agents.first else { return }
        Task { await use(spec, fresh: true) }
    }

    @objc func stopTurn() {
        chat?.stop()
    }

    /// Escape: Don't Allow on a waiting prompt.
    func escape() {
        guard let chat, case .ask(let ask)? = chat.items.last(where: { if case .ask(let ask) = $0 { ask.answer == nil } else { false } }) else { return }
        chat.choose(ask.id, option: nil)
    }

    override func cancelOperation(_ sender: Any?) {
        if NSApp.currentEvent?.keyCode == 53 { escape() } else { stopTurn() }
    }

    // MARK: Sending

    func sendTyped() {
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let chat, chat.state == .ready else { return }
        let note = noteChip
        let selection = selectionChip
        input.string = ""
        inputChanged()
        selectionOff = selection
        Task {
            await chat.send(text, note: note, selection: selection)
            updateChips()
        }
        updateChips()
    }

    /// The open note, unless its chip was removed.
    var noteChip: URL? {
        guard let note = context.note() else { return nil }
        return note == noteOff ? nil : note
    }

    /// The note's selection, unless its chip was removed or it was just sent.
    var selectionChip: AgentChat.Selection? {
        guard let selection = context.selection() else { return nil }
        return selection == selectionOff ? nil : selection
    }

    func updateChips() {
        if let note = context.note(), noteOff != nil, note != noteOff { noteOff = nil }
        for view in chips.arrangedSubviews { view.removeFromSuperview() }
        if let note = noteChip { chips.addArrangedSubview(chip(note.deletingPathExtension().lastPathComponent, symbol: "doc.text", remove: #selector(removeNote))) }
        if let selection = selectionChip { chips.addArrangedSubview(chip(selection.label, symbol: "text.alignleft", remove: #selector(removeSelection))) }
        chips.isHidden = chips.arrangedSubviews.isEmpty || inputBox?.isHidden == true
    }

    private func chip(_ title: String, symbol: String, remove: Selector) -> NSView {
        let label = AgentLook.label(title, font: AgentLook.small, color: AgentLook.ink)
        label.isSelectable = false
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove \(title)")!, target: self, action: remove)
        close.isBordered = false
        close.contentTintColor = AgentLook.ink2
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.toolTip = "Don't send \(title)"
        let row = NSStackView(views: [AgentLook.symbol(symbol), label, close])
        row.spacing = 4
        return AgentBox.around(row, inset: NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6), fill: AgentLook.fill, radius: 10)
    }

    @objc func removeNote() {
        noteOff = context.note()
        updateChips()
    }

    @objc func removeSelection() {
        selectionOff = context.selection()
        updateChips()
    }
}

extension AgentPanelController {
    // MARK: Drawing

    /// Draws item `index`, in place or at the end, and follows the bottom when the reader is there.
    func draw(_ index: Int) {
        guard let chat, chat.items.indices.contains(index) else { return }
        let atBottom = scroll.contentView.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 24
        let view = itemView(chat.items[index], chat: chat)
        if index < chatViews.count {
            let old = chatViews[index]
            transcript.insertArrangedSubview(view, at: transcript.arrangedSubviews.firstIndex(of: old) ?? transcript.arrangedSubviews.count)
            old.removeFromSuperview()
            chatViews[index] = view
        } else {
            transcript.addArrangedSubview(view)
            chatViews.append(view)
        }
        if case .user = chat.items[index] {
            view.trailingAnchor.constraint(equalTo: transcript.trailingAnchor, constant: -16).isActive = true
            (view as? NSStackView)?.arrangedSubviews.first?.widthAnchor.constraint(lessThanOrEqualTo: transcript.widthAnchor, multiplier: 0.8).isActive = true
        } else {
            view.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -32).isActive = true
        }
        if atBottom { scrollToEnd() }
    }

    func scrollToEnd() {
        transcript.layoutSubtreeIfNeeded()
        guard let document = scroll.documentView else { return }
        document.scroll(NSPoint(x: 0, y: max(document.frame.height - scroll.contentView.bounds.height, 0)))
    }

    /// The tool lines again, since their places count follows the marks.
    func redrawTools() {
        guard let chat else { return }
        for (index, item) in chat.items.enumerated() { if case .tool = item { draw(index) } }
    }

    /// The line over the transcript for the chat's state, and the header's Stop.
    func drawState() {
        guard let chat else { return }
        stopButton.isHidden = chat.state != .running
        let name = chat.spec.name
        switch chat.state {
        case .starting: show(chat, message: "Starting \(name)…")
        case .ready, .running:
            show(chat, message: chat.items.isEmpty ? "Ask about this note, or ask for a change. \(name)'s edits show up marked in the note." : nil)
        case .signIn:
            show(chat, message: "\(name) needs you to sign in. Run `\(chat.spec.signIn)` once in Terminal, then press Try Again.",
                 action: ("Try Again", #selector(startAgain)))
        case .stopped: show(chat, message: nil)
        case .failed(let message): show(chat, message: message, action: ("Look Again", #selector(lookAgain)))
        }
        input.isEditable = chat.state == .ready || chat.state == .running
        input.setValue(NSAttributedString(string: "Message \(name)", attributes: [.font: AgentLook.font, .foregroundColor: AgentLook.ink2]), forKey: "placeholderAttributedString")
    }

    func show(_ chat: AgentChat?, message: String?, action: (String, Selector)? = nil) {
        for view in status.arrangedSubviews { view.removeFromSuperview() }
        if let message { status.addArrangedSubview(AgentLook.label("", color: AgentLook.ink2).with(AgentLook.withCode(message, color: AgentLook.ink2))) }
        if let action { status.addArrangedSubview(AgentLook.button(action.0, self, action.1)) }
        status.isHidden = status.arrangedSubviews.isEmpty
        for view in status.arrangedSubviews { view.widthAnchor.constraint(lessThanOrEqualTo: transcript.widthAnchor, constant: -32).isActive = true }
    }

    @objc func startAgain() {
        guard let chat else { return }
        Task { await chat.start() }
    }

    @objc func lookAgain() {
        Task { await appear(again: true) }
    }

    @objc func setUp() {
        setUpHooks()
    }

    // MARK: Empty state

    /// No agent found: what to install, as copyable commands.
    func showEmpty() {
        chat = nil
        popup.isHidden = true
        newChatButton.isHidden = true
        stopButton.isHidden = true
        for view in [scroll, chips, inputBox] { view?.isHidden = true }
        for view in empty.arrangedSubviews { view.removeFromSuperview() }
        empty.isHidden = false
        let title = AgentLook.label("Chat with your coding agent", font: .systemFont(ofSize: 15, weight: .semibold))
        let text = AgentLook.label("Dewline talks to an agent you install yourself. It ships no model and needs no account.", color: AgentLook.ink2)
        empty.addArrangedSubview(title)
        empty.addArrangedSubview(text)
        empty.setCustomSpacing(20, after: text)
        for known in AgentDiscovery.known {
            let name = AgentLook.label(known.spec.name, font: AgentLook.strong)
            let copy = AgentLook.button("Copy", self, #selector(copyCommand(_:)))
            copy.identifier = NSUserInterfaceItemIdentifier(known.install)
            copy.toolTip = "Copy the install command"
            let line = NSStackView(views: [name, NSView(), copy])
            line.spacing = 8
            let command = AgentLook.label(known.install, font: AgentLook.mono, color: AgentLook.ink)
            command.lineBreakMode = .byCharWrapping
            let row = NSStackView(views: [line, command])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            empty.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: empty.widthAnchor, constant: -32).isActive = true
            line.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            command.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor).isActive = true
        }
        let buttons = NSStackView(views: [AgentLook.button("Look Again", self, #selector(lookAgain)), AgentLook.button("Add Agent…", self, #selector(addAgent))])
        buttons.spacing = 8
        empty.setCustomSpacing(20, after: empty.arrangedSubviews.last!)
        empty.addArrangedSubview(buttons)
        for view in [title, text] { view.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -32).isActive = true }
    }

    @objc func copyCommand(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        sender.title = "Copied"
    }

    /// Add Agent…: a name, a command, and its arguments, saved for Settings > Agents too.
    @objc func addAgent() {
        let fields = ["Name", "Command", "Arguments"].map { placeholder in
            let field = NSTextField(string: "")
            field.placeholderString = placeholder
            field.frame.size = NSSize(width: 280, height: 22)
            return field
        }
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 82)
        let alert = NSAlert()
        alert.messageText = "Add an agent"
        alert.informativeText = "Any program that speaks the Agent Client Protocol on stdin and stdout."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add Agent")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                let (name, command) = (fields[0].stringValue.trimmingCharacters(in: .whitespaces), fields[1].stringValue.trimmingCharacters(in: .whitespaces))
                guard response == .alertFirstButtonReturn, let self, !name.isEmpty, !command.isEmpty else { return }
                let arguments = fields[2].stringValue.split(separator: " ").map(String.init)
                AgentDiscovery.add(name: name, command: command, arguments: arguments, defaults: self.defaults)
                Task { await self.appear(again: true) }
            }
        }
    }
}

private extension NSTextField {
    func with(_ text: NSAttributedString) -> NSTextField {
        attributedStringValue = text
        return self
    }
}

extension AgentPanelController {
    // MARK: Items

    func itemView(_ item: AgentChat.Item, chat: AgentChat) -> NSView {
        switch item {
        case .user(let text, let context):
            let label = AgentLook.label(text)
            let box = AgentBox.around(label, inset: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10), fill: AgentLook.fill, radius: 10)
            let column = NSStackView(views: [box])
            column.orientation = .vertical
            column.alignment = .trailing
            column.spacing = 4
            if !context.isEmpty { column.addArrangedSubview(AgentLook.label(context.joined(separator: " · "), font: AgentLook.small, color: AgentLook.ink2)) }
            return column
        case .agent(let text):
            return AgentLook.label("").with(AgentLook.markdown(text))
        case .thought(let text):
            let toggle = NSButton(title: "Thinking", target: self, action: #selector(toggleThought(_:)))
            toggle.setButtonType(.pushOnPushOff)
            toggle.bezelStyle = .disclosure
            toggle.imagePosition = .imageLeading
            toggle.isBordered = false
            toggle.attributedTitle = NSAttributedString(string: "Thinking", attributes: [.font: AgentLook.small, .foregroundColor: AgentLook.ink2])
            toggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            toggle.alternateImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            toggle.contentTintColor = AgentLook.ink2
            let body = AgentLook.label(text, font: AgentLook.small, color: AgentLook.ink2)
            body.isHidden = true
            let column = NSStackView(views: [toggle, body])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            return column
        case .tool(let tool):
            return toolView(tool, chat: chat)
        case .plan(let steps):
            let column = NSStackView(views: steps.map { step in
                let (symbol, color) = switch step.status {
                case "completed": ("checkmark.square", AgentLook.ink2)
                case "in_progress": ("square.dotted", AgentLook.ink)
                default: ("square", AgentLook.ink)
                }
                let row = NSStackView(views: [AgentLook.symbol(symbol, color: color), AgentLook.label(step.content, color: color)])
                row.alignment = .firstBaseline
                row.spacing = 6
                return row
            })
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            return column
        case .ask(let ask):
            return askView(ask)
        case .notice(let text, let action):
            let row = NSStackView(views: [AgentLook.label(text, font: AgentLook.small, color: AgentLook.ink2)])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 6
            switch action {
            case .setUpHooks: row.addArrangedSubview(AgentLook.button("Set Up", self, #selector(setUp)))
            case .startAgain: row.addArrangedSubview(AgentLook.button("Start Again", self, #selector(startAgain)))
            case nil: break
            }
            return row
        }
    }

    @objc func toggleThought(_ sender: NSButton) {
        guard let body = (sender.superview as? NSStackView)?.arrangedSubviews.last else { return }
        body.isHidden = sender.state == .off
    }

    /// "Edited Launch plan.md · 3 places · Review": one line per tool call.
    func toolView(_ tool: AgentChat.Tool, chat: AgentChat) -> NSView {
        let symbol = switch tool.kind {
        case "edit", "delete", "move": "pencil"
        case "read": "doc.text"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "fetch": "globe"
        case "think": "brain"
        default: "wrench.and.screwdriver"
        }
        let name = tool.paths.first.map { ($0 as NSString).lastPathComponent }
        var parts: [String] = []
        if tool.kind == "edit", let name {
            parts.append(tool.status == "completed" ? "Edited \(name)" : tool.status == "failed" ? "Didn't edit \(name)" : "Editing \(name)")
        } else {
            parts.append(tool.title.isEmpty ? "Tool" : tool.title)
            if tool.status == "failed" { parts.append("Failed") }
        }
        let places = tool.kind == "edit" ? self.places(tool, chat: chat) : 0
        if places > 0 { parts.append(places == 1 ? "1 place" : "\(places) places") }
        let label = AgentLook.label(parts.joined(separator: " · "), color: tool.status == "completed" ? AgentLook.ink : AgentLook.ink2)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        let row = NSStackView(views: [AgentLook.symbol(symbol), label])
        row.spacing = 6
        if places > 0 {
            let review = NSButton(title: "Review", target: self, action: #selector(review(_:)))
            review.isBordered = false
            review.attributedTitle = NSAttributedString(string: "Review", attributes: [.font: AgentLook.font, .foregroundColor: ThemeStore.shared.color(.accent)])
            review.identifier = NSUserInterfaceItemIdentifier(tool.paths[0])
            row.addArrangedSubview(review)
        }
        return row
    }

    /// The marked changes this chat's agent has waiting in the tool's note.
    func places(_ tool: AgentChat.Tool, chat: AgentChat) -> Int {
        guard let path = tool.paths.first.flatMap({ try? chat.writes.resolve($0) }), let live = chat.writes.open(path)?.live else { return 0 }
        return live.changes.values.filter { $0.marked && $0.origin == .agent(.acp, session: chat.writes.session) }.count
    }

    /// Review: the note's first change from this agent, with the caret in it.
    @objc func review(_ sender: NSButton) {
        guard let chat, let path = sender.identifier.flatMap({ try? chat.writes.resolve($0.rawValue) }), let live = chat.writes.open(path)?.live,
            let first = live.changes.filter({ $0.value.marked && $0.value.origin == .agent(.acp, session: chat.writes.session) })
                .min(by: { $0.value.range.location < $1.value.range.location })
        else { return }
        live.reveal(first.key, caret: true)
    }

    /// The permission card: the request, then the agent's options in its order, with no default.
    func askView(_ ask: AgentChat.Ask) -> NSView {
        let column = NSStackView(views: [AgentLook.label("").with(AgentLook.withCode(ask.text))])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        if let answer = ask.answer {
            let chosen = ask.options.first { $0.id == answer }
            let text = chosen.map { $0.kind.hasPrefix("allow") ? ($0.kind == "allow_always" ? "Always allowed." : "Allowed once.") : "Not allowed." } ?? "Not allowed."
            column.addArrangedSubview(AgentLook.label(text, font: AgentLook.small, color: AgentLook.ink2))
        } else {
            let buttons = NSStackView(views: ask.options.map { option in
                let button = AgentLook.button(option.label, self, #selector(choose(_:)))
                button.identifier = NSUserInterfaceItemIdentifier("\(ask.id)\n\(option.id)")
                button.keyEquivalent = ""
                return button
            })
            buttons.spacing = 8
            column.addArrangedSubview(buttons)
        }
        return AgentBox.around(column, inset: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), fill: nil, stroke: AgentLook.rule)
    }

    @objc func choose(_ sender: NSButton) {
        guard let parts = sender.identifier?.rawValue.split(separator: "\n", maxSplits: 1), parts.count == 2, let id = Int(parts[0]) else { return }
        chat?.choose(id, option: String(parts[1]))
    }
}
