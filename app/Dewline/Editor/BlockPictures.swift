import AppKit
import ImageIO
import MdCore
import SwiftMath

/// A rendered block's picture and its size in points.
struct BlockPicture: Sendable {
    let image: CGImage
    let size: CGSize
}

/// The M0 math engine trial: both engines stay behind `typesetMath` until the decision record picks one.
enum MathEngine: String, CaseIterable, Sendable {
    case raTeX = "ratex"
    case swiftMath = "swiftmath"

    static var current: MathEngine {
        UserDefaults.standard.string(forKey: "DewlineMath").flatMap(MathEngine.init) ?? .raTeX
    }
}

/// What a picture depends on besides the column width, which only narrows it, so equal requests share a render.
struct PictureRequest: Hashable, Sendable {
    let kind: RenderedBlock.Kind
    /// The diagram, the TeX, or the image file's path.
    let source: String
    let scale: CGFloat
    /// The theme's colors in the view's appearance: a diagram takes them all and math the ink; an image takes none.
    let colors: DiagramColors?
    let engine: MathEngine

    /// Renders off the main thread, no wider than `width` points where the renderer can narrow.
    func render(width: CGFloat) -> Result<BlockPicture, RenderFailure> {
        Result { () throws(RenderFailure) in
            let image: CGImage
            switch kind {
            case .mermaid:
                image = try mermaidImage(source, colors: colors!, scale: scale, maxWidth: Int(width * scale))
            case .math:
                image = try typesetMath(source, engine: engine, size: 20, scale: scale, color: colors!.ink)
            case .image:
                guard !source.isEmpty else { throw RenderFailure("the note is not saved in a folder yet") }
                // Only a regular file: a pipe would hold the render queue forever.
                let url = URL(fileURLWithPath: source).resolvingSymlinksInPath()
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                    let file = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
                    let pixels = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                    pixels > 0
                else { throw RenderFailure("there is no image this Mac can read at \(source)") }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(pixels, height) * min(Int(width * scale), pixels) / pixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let decoded = CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary) else {
                    throw RenderFailure("the image at \(source) cannot be decoded")
                }
                image = decoded
            }
            return BlockPicture(image: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        }
    }
}

func typesetMath(_ tex: String, engine: MathEngine, size: CGFloat, scale: CGFloat, color: UInt32) throws(RenderFailure) -> CGImage {
    switch engine {
    case .raTeX:
        return try ratexImage(tex, size: size, scale: scale, color: color)
    case .swiftMath:
        let channels = [24, 16, 8, 0].map { CGFloat(color >> $0 & 0xFF) / 255 }
        let ink = NSColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: channels[3])
        let (error, typeset) = MTMathImage(latex: tex, fontSize: size, textColor: ink, labelMode: .display, textAlignment: .left).asImage()
        guard error == nil, let typeset else { throw RenderFailure(error?.localizedDescription ?? "SwiftMath made no picture") }
        // On macOS the image draws lazily, so drawing it here is part of typesetting.
        guard let context = CGContext(
            data: nil, width: Int((typeset.size.width * scale).rounded(.up)), height: Int((typeset.size.height * scale).rounded(.up)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RenderFailure("the picture is empty") }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        typeset.draw(in: CGRect(origin: .zero, size: typeset.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw RenderFailure("the picture is empty") }
        return image
    }
}
