// Draws each catalog family's name (20 pt) over its sample line (14 pt) as glyph outlines in a small PDF, which the
// Fonts pane shows until the family is installed (synthesis 2.9). It reads verified downloads laid out as
// <google/fonts folder>/<file>, registers nothing, and writes <family>.pdf.
// Usage: swift scripts/font-specimens.swift <downloads> app/Dewline/Specimens
import AppKit
import CoreText

let downloads = URL(filePath: CommandLine.arguments[1])
let output = URL(filePath: CommandLine.arguments[2])
let sample = "Public beta opens on 2 December."
let spacing: CGFloat = 3

func regular(in folder: URL) -> CTFontDescriptor? {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let descriptors = files.filter { $0.pathExtension == "ttf" }.sorted { $0.path < $1.path }.flatMap {
        CTFontManagerCreateFontDescriptorsFromURL($0 as CFURL) as? [CTFontDescriptor] ?? []
    }
    func style(_ descriptor: CTFontDescriptor) -> String {
        CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? ""
    }
    // Recursive names its upright default "Sans Linear".
    return descriptors.first { style($0) == "Regular" } ?? descriptors.first { style($0) == "Sans Linear" }
}

/// The line's outlines with its origin on the baseline, and its width.
func outlines(_ text: String, _ font: CTFont) -> (CGPath, CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for (glyph, position) in zip(glyphs, positions) {
            var transform = CGAffineTransform(translationX: position.x, y: position.y)
            if let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, &transform) { path.addPath(glyphPath) }
        }
    }
    return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

func lineHeight(_ font: CTFont) -> CGFloat {
    CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for folder in try FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
    guard let descriptor = regular(in: folder), let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { continue }
    let nameFont = CTFontCreateWithFontDescriptor(descriptor, 20, nil)
    let sampleFont = CTFontCreateWithFontDescriptor(descriptor, 14, nil)
    let (name, nameWidth) = outlines(family, nameFont)
    let (line, lineWidth) = outlines(sample, sampleFont)
    var box = CGRect(x: 0, y: 0, width: max(nameWidth, lineWidth).rounded(.up), height: (lineHeight(nameFont) + spacing + lineHeight(sampleFont)).rounded(.up))
    let url = output.appending(path: "\(family).pdf")
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: box.height - CTFontGetAscent(nameFont))
    context.addPath(name)
    context.translateBy(x: 0, y: -(CTFontGetDescent(nameFont) + CTFontGetLeading(nameFont) + spacing + CTFontGetAscent(sampleFont)))
    context.addPath(line)
    context.fillPath()
    context.endPDFPage()
    context.closePDF()
    print(url.lastPathComponent, Int(box.width), Int(box.height))
}
