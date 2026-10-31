import AppIntents
import AppKit
import MdCore

/// Captures into the inbox from outside a window, through the core append the CLI and MCP use.
enum Inbox {
    /// Appends `text` to the inbox at the `DewlineInboxPath` default, or at ~/Documents/Dewline/Inbox.md.
    static func append(_ text: String, source: String) throws(Refused) {
        let path = UserDefaults.standard.string(forKey: "DewlineInboxPath").map { ($0 as NSString).expandingTildeInPath }
        try appendToInbox(text, source: source, at: path)
    }
}

struct AddToInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Dewline Inbox"
    static let description = IntentDescription("Adds the text to the end of your Dewline inbox as a dated entry.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    func perform() async throws -> some IntentResult {
        try Inbox.append(text, source: "shortcuts")
        return .result()
    }
}

struct DewlineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToInboxIntent(),
            phrases: ["Add to \(.applicationName) Inbox", "Capture in \(.applicationName)"],
            shortTitle: "Add to Inbox",
            systemImageName: "tray.and.arrow.down"
        )
    }
}

/// The Services menu's "Add to Dewline Inbox", for selected text.
@MainActor
final class InboxService: NSObject {
    @objc func addToInbox(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "There is no text to add."
            return
        }
        do {
            try Inbox.append(text, source: "service")
        } catch let refused {
            error.pointee = (refused.errorDescription ?? "Nothing was added.") as NSString
        }
    }
}
