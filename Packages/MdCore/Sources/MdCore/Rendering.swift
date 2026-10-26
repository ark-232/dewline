internal import DewlineFFIBindings
import CoreGraphics
import Foundation
import ImageIO

/// Why a diagram or formula did not render, in words for the editor.
public struct RenderFailure: Error, Sendable, Equatable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// The editor theme's colors for a diagram, each sRGB 0xRRGGBBAA.
public struct DiagramColors: Hashable, Sendable {
    public let paper, ink, ink2, accent, rule, fill: UInt32

    public init(paper: UInt32, ink: UInt32, ink2: UInt32, accent: UInt32, rule: UInt32, fill: UInt32) {
        (self.paper, self.ink, self.ink2, self.accent, self.rule, self.fill) = (paper, ink, ink2, accent, rule, fill)
    }
}

/// A Mermaid diagram drawn by the engine in `colors` at `scale` pixels per point, narrowed to `maxWidth` pixels.
public func mermaidImage(_ source: String, colors: DiagramColors, scale: Double, maxWidth: Int) throws(RenderFailure) -> CGImage {
    let colors = DewlineFFIBindings.DiagramColors(
        paper: colors.paper, ink: colors.ink, ink2: colors.ink2, accent: colors.accent, rule: colors.rule, fill: colors.fill
    )
    let raster = try engine {
        try rasterizeSvg(svg: try renderMermaid(source: source, colors: colors), scale: Float(scale), maxWidth: UInt32(clamping: maxWidth))
    }
    guard let provider = CGDataProvider(data: raster.pixels as CFData),
        let image = CGImage(
            width: Int(raster.width), height: Int(raster.height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Int(raster.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    else { throw RenderFailure("the picture could not be made") }
    return image
}

/// Display math typeset by RaTeX at `size` points and `scale` pixels per point, in `color` (0xRRGGBBAA).
public func ratexImage(_ tex: String, size: Double, scale: Double, color: UInt32) throws(RenderFailure) -> CGImage {
    let png = try engine { try renderMath(tex: tex, size: Float(size), scale: Float(scale), color: color) }
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { throw RenderFailure("the picture could not be made") }
    return image
}

private func engine<T>(_ call: () throws -> T) throws(RenderFailure) -> T {
    do {
        return try call()
    } catch RenderError.TooLarge {
        throw RenderFailure("the source is over 50 KB")
    } catch RenderError.TooSlow {
        throw RenderFailure("rendering took over 250 ms")
    } catch RenderError.Invalid(let message) {
        throw RenderFailure(message)
    } catch {
        throw RenderFailure("\(error)")
    }
}
