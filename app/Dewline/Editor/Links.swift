import AppKit

/// Where a Cmd-click on a link or a wikilink goes.
enum LinkTarget: Equatable {
    /// An http, https or mailto address, which the system opens.
    case web(URL)
    /// A note to open in Dewline, and the heading to put the caret on.
    case note(URL, heading: String?)
    /// A note that is not there yet: where creating it puts it.
    case missing(URL)
    /// A heading in this document.
    case heading(String)
    /// Any other scheme (`javascript:`, `data:`, `file:` among them), an absolute path, or a file that is not a note.
    case refused
}

enum Links {
    static let schemes: Set<String> = ["http", "https", "mailto"]

    /// A markdown link's destination: an address, a relative path to a note with an optional `#heading`, or a heading
    /// here. Relative paths resolve from `folder`, the document's.
    static func target(of destination: String, from folder: URL?) -> LinkTarget {
        var text = destination.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        // Browsers drop blanks and control characters inside a scheme, so `java\tscript:` is still one.
        let squeezed = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
        }))
        if let colon = squeezed.firstIndex(of: ":"), !squeezed[..<colon].contains(where: { "/?#".contains($0) }) {
            let scheme = squeezed[..<colon].lowercased()
            guard schemes.contains(scheme), let url = URL(string: text), url.scheme?.lowercased() == scheme else { return .refused }
            return .web(url)
        }
        if text.hasPrefix("#") { return .heading(decoded(String(text.dropFirst()))) }
        let parts = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = decoded(String(parts[0]))
        guard let folder, !path.hasPrefix("/"), !path.hasPrefix("~"), ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) else {
            return .refused
        }
        let url = folder.appending(path: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing(url) }
        return .note(url, heading: parts.count > 1 ? decoded(String(parts[1])) : nil)
    }

    /// A wikilink's target, `note`, `note.md`, `folder/note` or `note#heading`, found by name in `folder` or below it,
    /// case-insensitively; the shortest path wins. A missing note would go in `folder`.
    static func target(ofWikilink target: String, in folder: URL?) -> LinkTarget {
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let heading = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        guard !name.isEmpty else { return heading.map(LinkTarget.heading) ?? .refused }
        guard let folder, !name.hasPrefix("/"), !name.hasPrefix("~"), !name.split(separator: "/").contains("..") else { return .refused }
        let stem = name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
        if let found = find(stem.lowercased(), in: folder) { return .note(found, heading: heading) }
        return .missing(folder.appending(path: stem + ".md").standardizedFileURL)
    }

    /// The note whose path from `folder`, without `.md`, is `stem` or ends with `/stem`, ignoring case.
    private static func find(_ stem: String, in folder: URL) -> URL? {
        // The walk's URLs extend the one it starts from, so its paths start with the root's.
        let folder = folder.resolvingSymlinksInPath()
        let root = folder.path
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var best: (url: URL, length: Int)?
        var seen = 0
        while let url = walk.nextObject() as? URL, seen < 50_000 {
            seen += 1
            guard url.pathExtension.lowercased() == "md" else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1).dropLast(3)).lowercased()
            guard relative == stem || relative.hasSuffix("/" + stem) else { continue }
            if best.map({ relative.count < $0.length }) ?? true { best = (url.standardizedFileURL, relative.count) }
        }
        return best?.url
    }

    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }
}

extension EditorTextView {
    /// The character under `point`, if the point is on it.
    private func character(at point: NSPoint) -> Int? {
        let index = characterIndexForInsertion(at: point)
        let length = textStorage!.length
        for candidate in [index, index - 1] where candidate >= 0 && candidate < length {
            let screen = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            guard let window else { continue }
            if convert(window.convertFromScreen(screen), from: nil).insetBy(dx: -1, dy: -1).contains(point) { return candidate }
        }
        return nil
    }

    /// The innermost span of `kinds` at `index`, in document offsets.
    private func span(at index: Int, _ kinds: (SyntaxSpan.Kind) -> Bool) -> SyntaxSpan? {
        styler.map.blocks(in: NSRange(location: index, length: 0)).flatMap { block in
            block.spans.map { $0.shifted(by: block.range.location) }
        }.last { kinds($0.kind) && NSLocationInRange(index, $0.range) }
    }

    /// Follows the link, wikilink, embed, footnote or tag under `point`; false when there is none.
    func follow(at point: NSPoint) -> Bool {
        guard let index = character(at: point), let span = span(at: index, { kind in
            [.link, .wikiLink, .embed, .footnoteReference, .footnoteDefinition, .tag].contains(kind)
        }) else { return false }
        let text = textStorage!.mutableString
        switch span.kind {
        case .link:
            guard let destination = destination(of: span) else { return false }
            follow(Links.target(of: destination, from: documentFolder))
        case .wikiLink, .embed:
            follow(Links.target(ofWikilink: wikilinkTarget(of: span), in: noteFolder ?? documentFolder))
        case .footnoteReference:
            guard let definition = footnoteDefinition(text.substring(with: span.content)) else { return false }
            jump(to: definition.range.location)
        case .footnoteDefinition:
            // Back from the definition's label to its first reference.
            guard index < span.content.location, let label = footnoteLabel(of: span), let reference = footnoteReference(label) else { return false }
            jump(to: reference)
        default:
            let tag = text.substring(with: span.range)
            if let findInFiles { findInFiles(tag) } else { NSSound.beep() }
        }
        return true
    }

    private func follow(_ target: LinkTarget) {
        switch target {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .note(let url, let heading):
            open(url, heading: heading)
        case .heading(let heading):
            if !jump(toHeading: heading) { NSSound.beep() }
        case .missing(let url):
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "\u{201C}\(url.deletingPathExtension().lastPathComponent)\u{201D} doesn\u{2019}t exist yet."
            alert.informativeText = "Create it in \(FileManager.default.displayName(atPath: url.deletingLastPathComponent().path))?"
            alert.addButton(withTitle: "Create Note")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn,
                    FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
                else { return }
                self?.open(url, heading: nil)
            }
        case .refused:
            NSSound.beep()
        }
    }

    private func open(_ url: URL, heading: String?) {
        if let openNote { return openNote(url, heading) }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    /// Puts the caret on the first heading titled `title`, ignoring case; false when there is none.
    @discardableResult
    func jump(toHeading title: String) -> Bool {
        let text = textStorage!.mutableString
        let wanted = title.trimmingCharacters(in: .whitespaces).lowercased()
        for block in styler.map.blocks(in: NSRange(location: 0, length: text.length)) {
            for span in block.spans {
                guard case .heading = span.kind else { continue }
                let content = text.substring(with: NSRange(location: block.range.location + span.content.location, length: span.content.length))
                if content.trimmingCharacters(in: .whitespaces).lowercased() == wanted {
                    jump(to: block.range.location + span.range.location)
                    return true
                }
            }
        }
        return false
    }

    private func jump(to location: Int) {
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// A wikilink's or embed's target: what comes before an alias's `|`, or its content.
    func wikilinkTarget(of span: SyntaxSpan) -> String {
        let text = textStorage!.mutableString
        let skip = span.kind == .embed ? 3 : 2
        let open = NSRange(location: span.range.location + skip, length: span.content.location - span.range.location - skip)
        return open.length > 0 ? String(text.substring(with: open).dropLast()) : text.substring(with: span.content)
    }

    /// A link's destination: an autolink's address, an inline link's, or a reference's from its definition.
    func destination(of span: SyntaxSpan) -> String? {
        let text = textStorage!.mutableString
        if text.character(at: span.range.location) == 0x3C { return text.substring(with: span.content) }
        let close = text.substring(with: NSRange(location: NSMaxRange(span.content), length: NSMaxRange(span.range) - NSMaxRange(span.content)))
        if close.hasPrefix("](") { return Self.address(String(close.dropFirst(2).dropLast())) }
        let label = close.hasPrefix("][") && close.count > 3 ? String(close.dropFirst(2).dropLast()) : text.substring(with: span.content)
        let wanted = Self.normalized(label)
        for block in styler.map.blocks(in: NSRange(location: 0, length: text.length)) {
            for definition in block.spans where definition.kind == .definition {
                let at = definition.shifted(by: block.range.location)
                guard Self.normalized(text.substring(with: at.content)) == wanted else { continue }
                let rest = text.substring(with: NSRange(location: NSMaxRange(at.content), length: NSMaxRange(at.range) - NSMaxRange(at.content)))
                return Self.address(String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    /// The address at the start of a destination and title.
    private static func address(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), let end = trimmed.firstIndex(of: ">") { return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]) }
        return String(trimmed.prefix { !$0.isWhitespace })
    }

    private static func normalized(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func footnoteLabel(of definition: SyntaxSpan) -> String? {
        let open = textStorage!.mutableString.substring(with: NSRange(location: definition.range.location, length: definition.content.location - definition.range.location))
        guard open.hasPrefix("[^"), let end = open.range(of: "]:") else { return nil }
        return String(open[open.index(open.startIndex, offsetBy: 2)..<end.lowerBound])
    }

    /// The definition of footnote `label`: its block's range and its text on one line.
    func footnoteDefinition(_ label: String) -> (range: NSRange, text: String)? {
        let text = textStorage!.mutableString
        let wanted = Self.normalized(label)
        for block in styler.map.blocks(in: NSRange(location: 0, length: text.length)) {
            for span in block.spans where span.kind == .footnoteDefinition {
                let at = span.shifted(by: block.range.location)
                guard footnoteLabel(of: at).map(Self.normalized) == wanted else { continue }
                let body = text.substring(with: at.content).split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                return (at.range, body)
            }
        }
        return nil
    }

    /// Where the first reference to footnote `label` starts.
    private func footnoteReference(_ label: String) -> Int? {
        let text = textStorage!.mutableString
        let wanted = Self.normalized(label)
        for block in styler.map.blocks(in: NSRange(location: 0, length: text.length)) {
            for span in block.spans where span.kind == .footnoteReference {
                let at = span.shifted(by: block.range.location)
                if Self.normalized(text.substring(with: at.content)) == wanted { return at.range.location }
            }
        }
        return nil
    }

    /// Shows the definition of the footnote reference under `point` in a popover, or closes the one showing.
    func hoverFootnote(at point: NSPoint) {
        let text = textStorage!.mutableString
        guard let index = character(at: point), let span = span(at: index, { $0 == .footnoteReference }),
            let definition = footnoteDefinition(text.substring(with: span.content)), let window
        else {
            footnotePopover?.close()
            footnotePopover = nil
            return
        }
        if let shown = footnotePopover, shown.isShown, shown.contentViewController?.representedObject as? NSRange == span.range { return }
        footnotePopover?.close()
        let label = NSTextField(wrappingLabelWithString: definition.text.isEmpty ? "Empty footnote" : definition.text)
        label.preferredMaxLayoutWidth = 320
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        let controller = NSViewController()
        controller.view = content
        controller.representedObject = span.range
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        let rect = convert(window.convertFromScreen(firstRect(forCharacterRange: span.range, actualRange: nil)), from: nil)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        footnotePopover = popover
    }
}
