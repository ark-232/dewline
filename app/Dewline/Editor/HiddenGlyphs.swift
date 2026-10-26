import AppKit

/// TextKit 1: characters carrying `.dewlineHidden` lay out as null glyphs.
final class HiddenGlyphs: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        let count = glyphRange.length
        let changed = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { changed.deallocate() }
        changed.initialize(from: properties, count: count)
        var hidden = false
        for index in 0..<count where storage.attribute(.dewlineHidden, at: characterIndexes[index], effectiveRange: nil) != nil {
            changed[index] = .null
            hidden = true
        }
        guard hidden else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }
}

extension NSAttributedString.Key {
    static let dewlineHidden = NSAttributedString.Key("DewlineHidden")
    static let dewlineMarkerFont = NSAttributedString.Key("DewlineMarkerFont")
}
