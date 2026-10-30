internal import DewlineFFIBindings
import Foundation

/// Why a system entry point (a `dewline://` link, the inbox intent or Service) did nothing, in words for the user.
public struct Refused: LocalizedError, Sendable {
    public let errorDescription: String?

    public init(_ reason: String) {
        errorDescription = reason
    }
}

/// `text` as the Quick Look page: the page export writes with `css` inlined, diagrams and math as their source, and no
/// image inlined.
public func previewPage(_ text: String, title: String, css: String) -> String {
    previewHtml(text: text, title: title, css: css)
}

/// Appends `text` to the inbox at `path`, or at ~/Documents/Dewline/Inbox.md, as one entry dated and labeled `source`.
public func appendToInbox(_ text: String, source: String, at path: String?) throws(Refused) {
    try refusing { try inboxAppend(path: path, source: source, text: text) }
}

/// `path` with every link resolved, if it lies inside the home folder and not inside ~/Library or a `.ssh` folder.
public func jailedPath(_ path: String) throws(Refused) -> String {
    try refusing { try DewlineFFIBindings.jailedPath(path: path) }
}

private func refusing<T>(_ call: () throws -> T) throws(Refused) -> T {
    do {
        return try call()
    } catch Refusal.Refused(let message) {
        throw Refused(message)
    } catch {
        throw Refused("\(error)")
    }
}
