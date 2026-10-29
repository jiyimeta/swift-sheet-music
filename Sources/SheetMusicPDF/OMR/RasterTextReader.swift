import Foundation

/// An axis-aligned box in deskewed PAGE pixels (top-left origin, y-down).
struct PixelRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double {
        x + width
    }

    var maxY: Double {
        y + height
    }

    var midX: Double {
        x + width / 2
    }
}

/// One recognized character, its box in deskewed page pixels.
struct RasterTextCharacter: Equatable {
    var text: String
    var rect: PixelRect
}

/// A recognized line with every box in DESKEWED PAGE pixels (y-down).
struct RasterTextLine: Equatable {
    var text: String
    var confidence: Float
    var rect: PixelRect
    var characters: [RasterTextCharacter]
}

/// Reads the text on a raster page by handing an `OMRTextRecognizer` overlapping, upscaled horizontal bands.
///
/// Small print (lyrics) is below what a recognizer reads reliably at scan resolution, and a whole page in one call
/// loses it; bands upscaled a few times read it. Everything here is portable Swift — the recognizer is the only
/// platform-specific step.
enum RasterTextReader {
    // These are the spike's settings; Task 9 tunes them.
    static let defaultStrips = 8
    static let defaultOverlapPx = 120
    static let defaultScale = 2

    /// Recognizes `bitmap` in `strips` overlapping horizontal bands, each upscaled `scale`× (bilinear).
    ///
    /// Band k's CORE is rows `[k·H/strips, (k+1)·H/strips)` (the last band's core runs to the bitmap's height). Its
    /// region is the core grown by `overlapPx` on both sides, clamped to the page. A line is kept only by the band
    /// whose core contains the line's centre, so a line seen twice in an overlap is returned once. A band whose
    /// recognition throws is skipped; `onStripFailure` is told its index and the error.
    static func lines(
        in bitmap: GrayBitmap,
        recognizer: any OMRTextRecognizer,
        strips: Int = defaultStrips,
        overlapPx: Int = defaultOverlapPx,
        scale: Int = defaultScale,
        onStripFailure: (Int, any Error) -> Void = { _, _ in },
    ) -> [RasterTextLine] {
        guard strips > 0, scale > 0, bitmap.width > 0, bitmap.height > 0 else { return [] }
        let height = bitmap.height
        var result: [RasterTextLine] = []

        for k in 0 ..< strips {
            let coreTop = k * height / strips
            let coreBottom = k == strips - 1 ? height : (k + 1) * height / strips
            guard coreBottom > coreTop else { continue }
            let regionTop = max(0, coreTop - overlapPx)
            let regionBottom = min(height, coreBottom + overlapPx)

            let image = upscaledBand(of: bitmap, rows: regionTop ..< regionBottom, scale: scale)
            let recognized: [OMRRecognizedLine]
            do {
                recognized = try recognizer.recognize(image)
            } catch {
                onStripFailure(k, error)
                continue
            }

            let originY = Double(regionTop)
            let factor = Double(scale)
            func toPage(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PixelRect {
                PixelRect(x: x / factor, y: originY + y / factor, width: w / factor, height: h / factor)
            }

            for line in recognized {
                let rect = toPage(line.x, line.y, line.width, line.height)
                let centerY = rect.y + rect.height / 2
                guard centerY >= Double(coreTop), centerY < Double(coreBottom) else { continue }
                let characters = line.characters.map {
                    RasterTextCharacter(text: $0.text, rect: toPage($0.x, $0.y, $0.width, $0.height))
                }
                result.append(RasterTextLine(
                    text: line.text, confidence: line.confidence, rect: rect, characters: characters,
                ))
            }
        }
        return result
    }

    /// The `rows` of `bitmap`, resampled `scale`× in both directions with bilinear interpolation.
    private static func upscaledBand(of bitmap: GrayBitmap, rows: Range<Int>, scale: Int) -> OMRTextImage {
        let srcW = bitmap.width
        let srcH = rows.count
        let dstW = srcW * scale
        let dstH = srcH * scale
        let factor = Double(scale)
        var out = [UInt8](repeating: 255, count: dstW * dstH)

        for dy in 0 ..< dstH {
            // Sample at pixel centres so the resample is not shifted by half a source pixel.
            let sy = min(max((Double(dy) + 0.5) / factor - 0.5, 0), Double(srcH - 1))
            let y0 = Int(sy)
            let y1 = min(y0 + 1, srcH - 1)
            let fy = sy - Double(y0)
            let row0 = (rows.lowerBound + y0) * srcW
            let row1 = (rows.lowerBound + y1) * srcW
            for dx in 0 ..< dstW {
                let sx = min(max((Double(dx) + 0.5) / factor - 0.5, 0), Double(srcW - 1))
                let x0 = Int(sx)
                let x1 = min(x0 + 1, srcW - 1)
                let fx = sx - Double(x0)
                let top = Double(bitmap.pixels[row0 + x0]) * (1 - fx) + Double(bitmap.pixels[row0 + x1]) * fx
                let bottom = Double(bitmap.pixels[row1 + x0]) * (1 - fx) + Double(bitmap.pixels[row1 + x1]) * fx
                out[dy * dstW + dx] = UInt8((top * (1 - fy) + bottom * fy).rounded())
            }
        }
        return OMRTextImage(pixels: out, width: dstW, height: dstH)
    }
}
