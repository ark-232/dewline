import AppKit
import Testing
@testable import Dewline

@MainActor
struct MarkdownDocumentTests {
    @Test func readsUTF8Text() throws {
        let document = MarkdownDocument()
        try document.read(from: Data("# Notes\r\n- one\n".utf8), ofType: "net.daringfireball.markdown")
        #expect(document.text == "# Notes\r\n- one\n")
    }

    @Test func editsWithoutMarkingTheDocumentEdited() throws {
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
        #expect(!document.isDocumentEdited)
    }

    @Test func refusesTextThatIsNotUTF8() {
        let document = MarkdownDocument()
        #expect(throws: CocoaError.self) {
            try document.read(from: Data([0x63, 0x61, 0x66, 0xE9]), ofType: "net.daringfireball.markdown")
        }
    }
}
