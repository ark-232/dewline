import AppKit

/// TextKit 1: characters carrying `.dewlineHidden` lay out as zero-advancement control glyphs, and lines carrying
/// `.dewlineBlock` take a rendered block's heights.
final class HiddenGlyphs: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        let storage = layoutManager.textStorage!
        let count = glyphRange.length
        let changed = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { changed.deallocate() }
        changed.initialize(from: properties, count: count)
        var hidden = false
        for index in 0..<count where storage.attribute(.dewlineHidden, at: characterIndexes[index], effectiveRange: nil) != nil {
            changed[index] = .controlCharacter
            hidden = true
        }
        guard hidden else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        layoutManager.textStorage!.attribute(.dewlineHidden, at: charIndex, effectiveRange: nil) == nil ? action : .zeroAdvancement
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let storage = layoutManager.textStorage!
        let index = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard index < storage.length, let line = storage.attribute(.dewlineBlock, at: index, effectiveRange: nil) as? BlockLine else {
            return false
        }
        let height: CGFloat
        switch line.role {
        case .picture(let picture, _): height = picture.size.height
        case .collapsed: height = 0
        case .error: return false
        }
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = height
        return true
    }
}

extension NSAttributedString.Key {
    static let dewlineHidden = NSAttributedString.Key("DewlineHidden")
    static let dewlineMarkerFont = NSAttributedString.Key("DewlineMarkerFont")
}
