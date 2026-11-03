import AppKit
import Carbon.HIToolbox

/// Capture: a one-line panel over whatever is in front. Return adds the line to the inbox and closes the panel; Esc
/// closes it. The Dock menu, File > Capture… and an optional global shortcut open it.
@MainActor
final class Capture: NSObject, NSTextFieldDelegate {
    static let shared = Capture()

    private var panel: NSPanel?
    private let field = NSTextField()
    /// Where entries go; the inbox in Settings unless a test sets another.
    var append: (String) throws -> Void = { try Inbox.append($0, source: "capture") }

    static func show() {
        shared.show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        field.stringValue = ""
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        NSApp.activate()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 52),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        field.placeholderString = "Add to Inbox"
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Add to Inbox")
        field.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        return panel
    }

    /// Return adds the line and closes; Esc closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            panel?.orderOut(nil)
            return true
        default:
            return false
        }
    }

    /// Adds `text` to the inbox and closes the panel; an empty line only closes it.
    func submit(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty {
            do {
                try append(line)
            } catch {
                NSApp.presentError(error)
                return
            }
        }
        field.stringValue = ""
        panel?.orderOut(nil)
    }

    // MARK: Global shortcut

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers `key` with `modifiers` (Carbon's cmdKey, optionKey…) as the system-wide Capture shortcut, replacing
    /// the last one; nil unregisters it. Settings > Files > Capture shortcut sets it; it is empty by default.
    func register(key: UInt32?, modifiers: UInt32) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let key else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Capture.show() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x6477_6C6E), id: 1)  // "dwln"
        RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
