import AppKit
import Testing
@testable import Dewline

@MainActor
struct MarkdownDocumentTests {
    private static let type = "net.daringfireball.markdown"
    @Test func readsUTF8Text() throws {
        let document = MarkdownDocument()
        try document.read(from: Data("# Notes\r\n- one\n".utf8), ofType: "net.daringfireball.markdown")
        #expect(document.text == "# Notes\r\n- one\n")
    }

    @Test func editsMarkTheDocumentEditedUntilUndone() throws {
        let document = MarkdownDocument()
        try document.read(from: Data("# Notes\n".utf8), ofType: "net.daringfireball.markdown")
        document.makeWindowControllers()
        let textView = try #require((document.windowControllers.first as? MainWindowController)?.textView)
        #expect(textView.string == "# Notes\n")
        #expect(textView.isEditable)
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        #expect(textView.string == "# Notes!\n")
        #expect(textView.undoManager === textView.styler.undoManager)
        textView.undoManager?.endUndoGrouping()
        #expect(document.isDocumentEdited)
        textView.undoManager?.undo()
        #expect(textView.string == "# Notes\n")
        #expect(!document.isDocumentEdited)
    }

    @Test func saveWritesTheEditAndKeepsEveryOtherByte() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let (url, document, textView) = try open(bom + Data("# Launch plan\r\n\r\nShip the béta on Friday.\nThen “rest”.\rNo newline".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        textView.insertText("Monday", replacementRange: (textView.string as NSString).range(of: "Friday"))
        try document.writeSafely(to: url, ofType: Self.type, for: .saveOperation)
        #expect(try Data(contentsOf: url) == bom + Data("# Launch plan\r\n\r\nShip the béta on Monday.\nThen “rest”.\rNo newline".utf8))
        // What the save wrote is the new base, so the next save writes too.
        textView.insertText("Tuesday", replacementRange: (textView.string as NSString).range(of: "Monday"))
        try document.writeSafely(to: url, ofType: Self.type, for: .saveOperation)
        #expect(try Data(contentsOf: url) == bom + Data("# Launch plan\r\n\r\nShip the béta on Tuesday.\nThen “rest”.\rNo newline".utf8))
    }

    @Test func saveRefusesAChangeOnDiskAndWritesNothing() throws {
        let (url, document, textView) = try open(Data("# Launch plan\r\n".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        textView.insertText("Ship on Friday.\r\n", replacementRange: NSRange(location: 15, length: 0))
        let theirs = Data("# Launch plan\r\nAn agent wrote this.\r\n".utf8)
        try theirs.write(to: url)
        #expect(throws: SaveConflict.self) {
            try document.writeSafely(to: url, ofType: Self.type, for: .saveOperation)
        }
        #expect(try Data(contentsOf: url) == theirs)
        #expect(textView.string == "# Launch plan\r\nShip on Friday.\r\n")
    }

    @Test func refusesTextThatIsNotUTF8() {
        let document = MarkdownDocument()
        #expect(throws: CocoaError.self) {
            try document.read(from: Data([0x63, 0x61, 0x66, 0xE9]), ofType: "net.daringfireball.markdown")
        }
    }

    /// A FIFO would block the main thread until a writer came, and /dev/zero would never end.
    @Test func readsOnlyRegularFilesAndNeverWaitsOnAPipe() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pipe = folder.appending(path: "plan.md")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        for url in [pipe, URL(fileURLWithPath: "/dev/zero"), folder, folder.appending(path: "missing.md")] {
            #expect(throws: CocoaError.self, "\(url.path)") { try MarkdownDocument().read(from: url, ofType: Self.type) }
        }
    }

    /// A document for `bytes` in a new temporary folder, in a window that is never shown.
    private func open(_ bytes: Data) throws -> (URL, MarkdownDocument, EditorTextView) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "launch-plan.md")
        try bytes.write(to: url)
        let document = MarkdownDocument()
        document.snapshots = folder.appending(path: "snapshots")
        try document.read(from: url, ofType: Self.type)
        // Without a fileURL the window leaves the recent files in user defaults alone.
        document.makeWindowControllers()
        let textView = try #require((document.windowControllers.first as? MainWindowController)?.textView)
        return (url, document, textView)
    }
}
