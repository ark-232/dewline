import AppKit
import MdCore

/// `dewline://open?path=…&line=…` and `dewline://export?path=…&to=pdf&out=…`. Every path goes through the core's
/// jail: inside the home folder, never inside ~/Library or a `.ssh` folder. An export writes only a file named for
/// its format, so a link can't overwrite anything else.
@MainActor
enum SchemeLinks {
    static func handle(_ url: URL) {
        do {
            try run(url)
        } catch {
            NSApp.presentError(error)
        }
    }

    private static func run(_ url: URL) throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        func path(_ name: String) throws(Refused) -> URL {
            guard let path = value(name), !path.isEmpty else { throw Refused("The link has no \(name).") }
            return URL(fileURLWithPath: try jailedPath((path as NSString).expandingTildeInPath))
        }
        switch url.host() {
        case "open":
            let line = value("line").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            try delegate.show(try path("path"), line: line, column: nil)
        case "export":
            let to = value("to")?.lowercased() ?? "pdf"
            guard let format = Export.Format.allCases.first(where: { $0.name.lowercased() == to }) else {
                throw Refused("Dewline exports HTML or PDF, not \(to).")
            }
            let file = try path("path")
            let out = try path("out")
            guard out.pathExtension.lowercased() == format.type.preferredFilenameExtension else {
                throw Refused("The export has to be named .\(format.type.preferredFilenameExtension ?? to).")
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            Task {
                do {
                    try await Export.write(
                        text, title: file.deletingPathExtension().lastPathComponent, as: format, to: out,
                        folder: file.deletingLastPathComponent()
                    )
                } catch {
                    NSApp.presentError(error)
                }
            }
        default:
            throw Refused("Dewline doesn’t know the link \(url.absoluteString).")
        }
    }
}
