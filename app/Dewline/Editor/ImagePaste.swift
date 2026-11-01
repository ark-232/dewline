import AppKit
import UniformTypeIdentifiers

extension EditorTextView {
    /// Saves pasted or dropped images as PNG beside the document, or in an "attachments" folder beside it when Settings >
    /// Files says so, and links them at the selection, as one edit.
    /// Returns false for a pasteboard without images, or with text beside an image, which pastes as text.
    func insertImages(from pboard: NSPasteboard) -> Bool {
        let files = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
        let types = pboard.types ?? []
        var images: [Data] = []
        if !files.isEmpty {
            images = files.compactMap { NSImage(contentsOf: $0).flatMap(Self.png) }
        } else if !types.contains(.fileURL), !types.contains(.string), !types.contains(.rtf) {
            images = (pboard.data(forType: .png).map { [$0] }) ?? NSImage(pasteboard: pboard).flatMap(Self.png).map { [$0] } ?? []
        }
        guard !images.isEmpty else { return false }
        guard let folder = documentFolder else {
            askToSave()
            return true
        }
        let subfolder = Preferences.shared.attachments == .subfolder ? "attachments/" : ""
        let target = folder.appending(path: subfolder, directoryHint: .isDirectory)
        var links: [String] = []
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for image in images { links.append("![](\(subfolder)\(try save(image, in: target)))") }
        } catch {
            window.map { presentError(error, modalFor: $0, delegate: nil, didPresent: nil, contextInfo: nil) }
            return true
        }
        replace(selectedRange(), with: links.joined(separator: "\n"))
        return true
    }

    /// Writes `png` to `image-<date>-<n>.png` in `folder`, at the first `n` no file has, and returns the name.
    private func save(_ png: Data, in folder: URL) throws -> String {
        let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        var number = 1
        while true {
            let name = "image-\(date)-\(number).png"
            do {
                try png.write(to: folder.appending(path: name), options: .withoutOverwriting)
                return name
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }

    private static func png(_ image: NSImage) -> Data? {
        image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }

    /// An untitled document has no folder for its images.
    private func askToSave() {
        guard let window, let document = window.windowController?.document as? NSDocument else { return }
        let alert = NSAlert()
        alert.messageText = "Save this document to add images"
        alert.informativeText = "Dewline saves a pasted image beside the document, so the document needs a folder first."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { document.saveAs(nil) }
        }
    }
}
