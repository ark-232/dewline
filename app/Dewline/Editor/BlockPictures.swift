import AppKit
import ImageIO
import MdCore

/// A rendered block's picture and its size in points.
struct BlockPicture: Sendable {
    let image: CGImage
    let size: CGSize
}

/// What a picture depends on besides the column width, which only narrows it, so equal requests share a render.
struct PictureRequest: Hashable, Sendable {
    let kind: RenderedBlock.Kind
    /// The diagram, the TeX, or the image file's path.
    let source: String
    let scale: CGFloat
    /// The theme's colors in the view's appearance: a diagram takes them all and math the ink; an image takes none.
    let colors: DiagramColors?

    /// Renders off the main thread, no wider than `width` points where the renderer can narrow.
    func render(width: CGFloat) -> Result<BlockPicture, RenderFailure> {
        Result { () throws(RenderFailure) in
            let image: CGImage
            switch kind {
            case .mermaid:
                image = try mermaidImage(source, colors: colors!, scale: scale, maxWidth: Int(width * scale))
            case .math:
                image = try ratexImage(source, size: 20, scale: scale, color: colors!.ink)
            case .frontMatter:
                throw RenderFailure("front matter folds without a picture")
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
