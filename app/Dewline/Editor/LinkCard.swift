import AppKit
import MdCore

/// A paragraph that is only an http or https address, `https://…` or `<https://…>`, drawn as a card with the page's
/// title and picture while the selection is outside it. The address stays in the storage, hidden, and the card never
/// changes the file. Pages load only for cards in the viewport.
@MainActor
final class LinkCards {
    weak var textView: EditorTextView?
    var previews = LinkPreviews.shared
    private let map: BlockMap
    /// The cards showing their address.
    private var revealed: Set<NSRange> = []
    private var pictures: [Key: BlockPicture] = [:]
    /// Whether each address's card was last drawn with its page.
    private var drawnLoaded: [URL: Bool] = [:]
    private var loadScheduled = false

    static let maxWidth: CGFloat = 480

    private struct Key: Hashable {
        let url: URL
        let width: CGFloat
        let scale: CGFloat
        let dark: Bool
        let loaded: Bool
    }

    init(map: BlockMap) {
        self.map = map
        NotificationCenter.default.addObserver(self, selector: #selector(previewsDidChange(_:)), name: LinkPreviews.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    /// The address of a paragraph that holds only one, or nil.
    nonisolated static func url(ofParagraph text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), text.hasSuffix(">") { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }),
            let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host(percentEncoded: false)?.isEmpty == false
        else { return nil }
        return url
    }

    /// The paragraph blocks drawn as cards, with their addresses, in document offsets.
    private func cards(in range: NSRange, of text: NSString, touching: Bool = false) -> [(range: NSRange, url: URL)] {
        guard previews.isOn else { return [] }
        return (touching ? map.blocks(touching: range) : map.blocks(in: range)).compactMap { block in
            guard block.kind == .paragraph, block.range.length < 2048,
                let url = Self.url(ofParagraph: text.substring(with: block.range)), LinkPreviews.allows(url)
            else { return nil }
            var end = NSMaxRange(block.range)
            while end > block.range.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
            return (NSRange(location: block.range.location, length: end - block.range.location), url)
        }
    }

    /// Moves the revealed cards past an edit the map has taken.
    func textDidChange(edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        revealed = Set(revealed.compactMap { range in
            if NSMaxRange(range) < edited.location { return range }
            return range.location > oldEnd ? NSRange(location: range.location + delta, length: range.length) : nil
        })
    }

    /// The cards the selection entered or left since they were last styled.
    func revealChanges(_ selection: [NSRange]) -> [NSRange] {
        guard let text = textView?.textStorage?.mutableString else { return [] }
        let now = Set(selection.flatMap { cards(in: $0, of: text, touching: true) }.map(\.range).filter { Self.touches($0, selection) })
        return Array(now.symmetricDifference(revealed))
    }

    /// Styles the cards in `styled`, a copy of the storage from `offset` on, for a selection in its coordinates.
    func style(_ styled: NSMutableAttributedString, at offset: Int, selection: [NSRange]) {
        let whole = NSRange(location: offset, length: styled.length)
        revealed = revealed.filter { !NSLocationInRange($0.location, whole) }
        guard let textView, let storage = textView.textStorage else { return }
        let width = min((textView.textContainer?.size.width ?? 0) - 2 * (textView.textContainer?.lineFragmentPadding ?? 0), Self.maxWidth).rounded(.down)
        guard width > 0 else { return }
        for card in cards(in: whole, of: storage.mutableString) {
            let local = NSRange(location: card.range.location - offset, length: card.range.length)
            guard local.location >= 0, NSMaxRange(local) <= styled.length else { continue }
            if Self.touches(local, selection) {
                revealed.insert(card.range)
                continue
            }
            let preview = previews.cached(card.url) ?? LinkPreview(url: card.url)
            drawnLoaded[card.url] = preview.isLoaded
            let picture = picture(preview, width: width, in: textView)
            let paragraph = NSIntersectionRange(styled.mutableString.paragraphRange(for: local), NSRange(location: 0, length: styled.length))
            styled.addAttributes([.foregroundColor: NSColor.clear, .font: MarkdownStyler.hiddenFont], range: local)
            styled.removeAttribute(.underlineStyle, range: local)
            styled.addAttribute(.dewlineBlock, value: BlockLine(.picture(picture, label: preview.title ?? card.url.absoluteString)), range: paragraph)
            let lines = NSMutableParagraphStyle()
            lines.minimumLineHeight = picture.size.height
            lines.maximumLineHeight = picture.size.height
            styled.addAttribute(.paragraphStyle, value: lines, range: paragraph)
        }
        scheduleLoad()
    }

    private func picture(_ preview: LinkPreview, width: CGFloat, in textView: EditorTextView) -> BlockPicture {
        let appearance = textView.effectiveAppearance
        let key = Key(url: preview.url, width: width, scale: textView.window?.backingScaleFactor ?? 2, dark: appearance.isDark, loaded: preview.isLoaded)
        if let picture = pictures[key] { return picture }
        if pictures.count > 128 { pictures = [:] }
        let picture = LinkCard.picture(preview, width: width, scale: key.scale, appearance: appearance)
        pictures[key] = picture
        return picture
    }

    /// Asks for the pages of the cards in the viewport once the current event is done, and redraws a card whose page
    /// arrived since it was drawn.
    func scheduleLoad() {
        guard !loadScheduled else { return }
        loadScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.loadScheduled = false
                self?.loadVisible()
            }
        }
    }

    private func loadVisible() {
        guard previews.isOn, let textView, let storage = textView.textStorage, let layout = textView.textLayoutManager,
            let content = layout.textContentManager, let viewport = layout.textViewportLayoutController.viewportRange
        else { return }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard end > start else { return }
        for card in cards(in: NSRange(location: start, length: end - start), of: storage.mutableString) {
            guard let preview = previews.metadata(for: card.url), preview.isLoaded, drawnLoaded[card.url] == false else { continue }
            textView.styler.restyleNow(card.range)
        }
    }

    @objc private func previewsDidChange(_ notification: Notification) {
        guard let textView, let storage = textView.textStorage else { return }
        guard notification.object == nil else { return scheduleLoad() }
        // Previews turned on or off: every card paragraph changes shape.
        let text = storage.mutableString
        for block in map.blocks(in: NSRange(location: 0, length: text.length)) where block.kind == .paragraph {
            guard block.range.length < 2048, Self.url(ofParagraph: text.substring(with: block.range)) != nil else { continue }
            textView.styler.restyleNow(block.range)
        }
    }

    @objc private func themeDidChange() {
        pictures = [:]
    }

    private static func touches(_ range: NSRange, _ selection: [NSRange]) -> Bool {
        selection.contains { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }
}

/// A preview drawn as a card: the page's picture across the top, then its title in two lines at most and its host;
/// without a picture, the icon beside them; before the page arrives, the host alone. Radius 10, the code fill, no
/// shadow.
enum LinkCard {
    static let radius: CGFloat = 10
    private static let pad: CGFloat = 12

    @MainActor
    static func picture(_ preview: LinkPreview, width: CGFloat, scale: CGFloat, appearance: NSAppearance) -> BlockPicture {
        let store = ThemeStore.shared
        var picture: BlockPicture!
        appearance.performAsCurrentDrawingAppearance {
            let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let truncating = NSMutableParagraphStyle()
            truncating.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: preview.title ?? preview.host, attributes: [.font: titleFont, .foregroundColor: store.color(.ink)])
            let host = preview.title == nil ? nil : NSAttributedString(string: preview.host, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: store.color(.ink2), .paragraphStyle: truncating,
            ])
            let icon = preview.image == nil ? preview.icon : nil
            let iconSide: CGFloat = icon == nil ? 0 : 32
            let textX = pad + (icon == nil ? 0 : iconSide + 10)
            let textWidth = max(width - textX - pad, 1)
            let lineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
            let titleHeight = min(ceil(title.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]
            ).height), 2 * lineHeight)
            let hostHeight: CGFloat = host == nil ? 0 : 16
            let footer = max(10 + titleHeight + hostHeight + 10, icon == nil ? 0 : iconSide + 2 * pad)
            let imageHeight: CGFloat = preview.image == nil ? 0 : min((width / 1.91).rounded(), 260)
            let size = CGSize(width: width, height: imageHeight + footer)
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let card = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: radius, yRadius: radius)
            store.color(.codeBackground).setFill()
            card.fill()
            card.addClip()
            if let image = preview.image, image.size.width > 0, image.size.height > 0 {
                // Fills the top, cropped to its middle.
                let area = CGRect(x: 0, y: 0, width: width, height: imageHeight)
                let fill = max(area.width / image.size.width, area.height / image.size.height)
                let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: area).addClip()
                image.draw(
                    in: CGRect(x: (area.width - drawn.width) / 2, y: (area.height - drawn.height) / 2, width: drawn.width, height: drawn.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
                )
                NSGraphicsContext.restoreGraphicsState()
            }
            if let icon {
                let frame = CGRect(x: pad, y: imageHeight + (footer - iconSide) / 2, width: iconSide, height: iconSide)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
                icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            let top = imageHeight + (footer - titleHeight - hostHeight) / 2
            title.draw(with: CGRect(x: textX, y: top, width: textWidth, height: titleHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            host?.draw(with: CGRect(x: textX, y: top + titleHeight + 2, width: textWidth, height: hostHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            NSGraphicsContext.restoreGraphicsState()
            picture = BlockPicture(image: context.makeImage()!, size: size)
        }
        return picture
    }
}

/// Over the text: a link under the pointer gets its underline at full strength, and a web link held under it for
/// 600 ms opens its card in a 320-point popover, which closes 150 ms after the pointer leaves. The view takes no
/// clicks and draws nothing; the underline is a rendering attribute, so the storage stays as it is.
@MainActor
final class LinkHover: NSView {
    weak var textView: EditorTextView?
    var previews = LinkPreviews.shared
    private var hovered: (range: NSRange, url: URL?)?
    private var opening: Timer?
    private var closing: Timer?
    private(set) var popover: NSPopover?
    private var shown: URL?

    static let openDelay: TimeInterval = 0.6
    static let closeDelay: TimeInterval = 0.15
    static let popoverWidth: CGFloat = 320

    init(textView: EditorTextView) {
        self.textView = textView
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        NotificationCenter.default.addObserver(self, selector: #selector(previewsDidChange(_:)), name: LinkPreviews.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("LinkHover is built in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = textView?.enclosingScrollView?.contentView else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func scrolled() {
        textView?.styler.cards.scheduleLoad()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let textView else { return }
        hover(textView.link(at: textView.convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        hover(nil)
    }

    /// Points at `link`, a link's range and its address when it is a web link, or at no link.
    func hover(_ link: (range: NSRange, url: URL?)?) {
        guard link?.range != hovered?.range || link?.url != hovered?.url else { return }
        if let old = hovered { underline(old.range, strong: false) }
        hovered = link
        opening?.invalidate()
        opening = nil
        guard let link else { return scheduleClose() }
        underline(link.range, strong: true)
        guard let url = link.url, previews.isOn, LinkPreviews.allows(url) else { return scheduleClose() }
        closing?.invalidate()
        closing = nil
        if popover?.isShown == true, shown == url { return }
        opening = Timer.scheduledTimer(withTimeInterval: Self.openDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    private func scheduleClose() {
        guard popover != nil, closing == nil else { return }
        closing = Timer.scheduledTimer(withTimeInterval: Self.closeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        closing = nil
        popover?.close()
        popover = nil
        shown = nil
    }

    private func open() {
        opening = nil
        guard let textView, let window = textView.window, let hovered, let url = hovered.url else { return }
        popover?.close()
        let preview = previews.metadata(for: url) ?? LinkPreview(url: url)
        let controller = NSViewController()
        controller.view = NSImageView()
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        self.popover = popover
        shown = url
        fill(popover, with: preview)
        let rect = textView.convert(window.convertFromScreen(textView.firstRect(forCharacterRange: hovered.range, actualRange: nil)), from: nil)
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
    }

    private func fill(_ popover: NSPopover, with preview: LinkPreview) {
        guard let textView, let view = popover.contentViewController?.view as? NSImageView else { return }
        let picture = LinkCard.picture(
            preview, width: Self.popoverWidth, scale: textView.window?.backingScaleFactor ?? 2, appearance: textView.effectiveAppearance
        )
        view.image = NSImage(cgImage: picture.image, size: picture.size)
        view.frame.size = picture.size
        popover.contentSize = picture.size
    }

    @objc private func previewsDidChange(_ notification: Notification) {
        guard let popover, let shown else { return }
        guard previews.isOn else { return close() }
        if let url = notification.object as? URL, url == shown, let preview = previews.cached(url) { fill(popover, with: preview) }
    }

    private func underline(_ range: NSRange, strong: Bool) {
        guard let layout = textView?.textLayoutManager, let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end)
        else { return }
        if strong {
            layout.addRenderingAttribute(.underlineColor, value: ThemeStore.shared.color(.accent), for: textRange)
        } else {
            layout.removeRenderingAttribute(.underlineColor, for: textRange)
        }
    }
}
