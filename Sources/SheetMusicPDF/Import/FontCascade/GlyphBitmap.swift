#if canImport(CoreGraphics)
    import CoreGraphics
    import CoreText
#endif
import Foundation

/// A glyph outline rasterized into a fixed-size, scale- and translation-
/// invariant coverage grid. This is deliberately the SAME representation the
/// future OMR symbol classifier consumes, so the nearest-neighbor matcher here
/// can later be swapped for a CNN without changing the pipeline.
struct GlyphBitmap: Hashable {
    static let size = 32
    /// `size * size` coverage samples, row-major, top-left origin, 0…255.
    var coverage: [UInt8]
}

/// Rasterize `path` into a `size × size` coverage grid. The path's bounding box
/// is scaled UNIFORMLY (aspect preserved) to fit the frame with a 1-pixel
/// margin and centered, so absolute font size and position drop out while the
/// aspect ratio — which separates e.g. a notehead from a flag — is preserved.
func normalizedBitmap(path: CGPath, size: Int = GlyphBitmap.size) -> GlyphBitmap {
    let box = path.boundingBoxOfPath
    guard box.width > 0, box.height > 0,
          let space = CGColorSpace(name: CGColorSpace.linearGray),
          let ctx = CGContext(
              data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size, space: space,
              bitmapInfo: CGImageAlphaInfo.none.rawValue,
          )
    else { return GlyphBitmap(coverage: [UInt8](repeating: 0, count: size * size)) }

    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let margin: CGFloat = 1
    let usable = CGFloat(size) - margin * 2
    let scale = min(usable / box.width, usable / box.height)
    let dx = (CGFloat(size) - box.width * scale) / 2 - box.minX * scale
    let dy = (CGFloat(size) - box.height * scale) / 2 - box.minY * scale
    // Scale about the origin, then translate — so a point at box.minX lands
    // at (size - box.width * scale) / 2, i.e. centered.
    var transform = CGAffineTransform(scaleX: scale, y: scale)
        .concatenating(CGAffineTransform(translationX: dx, y: dy))

    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.addPath(path.copy(using: &transform) ?? path)
    ctx.fillPath(using: .evenOdd)

    guard let data = ctx.data else {
        return GlyphBitmap(coverage: [UInt8](repeating: 0, count: size * size))
    }
    let buf = data.bindMemory(to: UInt8.self, capacity: size * size)
    return GlyphBitmap(coverage: Array(UnsafeBufferPointer(start: buf, count: size * size)))
}

/// Build a `CTFont` from an embedded font program so its glyph outlines can be
/// read with `CTFontCreatePathForGlyph`. Returns nil for a program CoreGraphics
/// cannot parse (bare CFF without an OpenType wrapper, damaged subsets).
func makeCTFont(
    program: Data, kind: PDFImporter.EmbeddedFont.ProgramKind, size: CGFloat = 1000,
) -> CTFont? {
    guard let provider = CGDataProvider(data: program as CFData),
          let cgFont = CGFont(provider) else { return nil }
    // `kind` is carried for diagnostics only — CGFont sniffs the format
    // itself. Task 8's spike records which kinds actually parse; if a kind
    // proves unsupported, branch here then, not speculatively now.
    _ = kind
    return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
}
