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

/// Reads the text on a raster page by handing an `OMRTextRecognizer` overlapping, upscaled tiles: horizontal bands,
/// each cut into column tiles when the page is wide.
///
/// Small print (lyrics) is below what a recognizer reads reliably at scan resolution, and a whole page in one call
/// loses it; bands upscaled a few times read it. A very wide page (a continuous-view export tens of thousands of
/// pixels across) makes even one band too wide for the recognizer, which then returns nothing, so every band is also
/// cut into columns no wider than `maxTileWidthPx`. Everything here is portable Swift — the recognizer is the only
/// platform-specific step.
enum RasterTextReader {
    // These are the spike's settings; Task 9 tunes them.
    static let defaultStrips = 8
    static let defaultOverlapPx = 120
    static let defaultScale = 2
    /// Source pixels, before scaling: an A4 page at 300 dpi (2 480 px) stays one column.
    static let defaultMaxTileWidthPx = 2600

    /// A tile's extent along one axis: the CORE it owns and the REGION (core grown by the overlap) it reads.
    private struct Span {
        var core: Range<Int>
        var region: Range<Int>
    }

    /// Recognizes `bitmap` in `strips` overlapping horizontal bands, each upscaled `scale`× (bilinear), and each band
    /// in column tiles when the bitmap is wider than `maxTileWidthPx`.
    ///
    /// Band k's CORE is rows `[k·H/strips, (k+1)·H/strips)` (the last band's core runs to the bitmap's height). Its
    /// region is the core grown by `overlapPx` on both sides, clamped to the page. A line is kept only by the band
    /// whose core contains the line's centre, so a line seen twice in an overlap is returned once.
    ///
    /// With `cols = ceil(width / maxTileWidthPx)` above one, column c's core is `[c·W/cols, (c+1)·W/cols)` (the last
    /// column's core runs to the bitmap's width) and its region is grown by `overlapPx` the same way. Columns cut
    /// lines, so ownership there is per CHARACTER: a tile keeps the characters whose horizontal centre lies in its
    /// column core, rebuilds the line from them (the recognizer's text cut to those characters, keeping its spaces
    /// between them; rect their union) and drops a line left with none. A line crossing a column boundary therefore
    /// comes back as two lines, one per column. `OCRTextGlyphs` places tokens, not whole lines, so the split only
    /// matters for a token straddling the boundary, which comes back as two. With a single column nothing is
    /// filtered and the recognizer's text and rect pass through.
    ///
    /// A tile whose recognition throws is skipped; `onStripFailure` is told its BAND index and the error, once per
    /// failed tile (a band with three failing tiles reports its index three times).
    static func lines(
        in bitmap: GrayBitmap,
        recognizer: any OMRTextRecognizer,
        strips: Int = defaultStrips,
        overlapPx: Int = defaultOverlapPx,
        scale: Int = defaultScale,
        maxTileWidthPx: Int = defaultMaxTileWidthPx,
        onStripFailure: (Int, any Error) -> Void = { _, _ in },
    ) -> [RasterTextLine] {
        guard strips > 0, scale > 0, bitmap.width > 0, bitmap.height > 0 else { return [] }
        let maxWidth = max(1, maxTileWidthPx)
        let cols = max(1, (bitmap.width + maxWidth - 1) / maxWidth)
        var result: [RasterTextLine] = []

        for k in 0 ..< strips {
            guard let rows = span(index: k, count: strips, length: bitmap.height, overlap: overlapPx) else { continue }
            for c in 0 ..< cols {
                guard let columns = span(index: c, count: cols, length: bitmap.width, overlap: overlapPx) else {
                    continue
                }
                let image = upscaledTile(of: bitmap, rows: rows.region, columns: columns.region, scale: scale)
                let recognized: [OMRRecognizedLine]
                do {
                    recognized = try recognizer.recognize(image)
                } catch {
                    onStripFailure(k, error)
                    continue
                }
                result += ownedLines(
                    recognized, rows: rows, columns: columns, scale: scale, splitsColumns: cols > 1,
                )
            }
        }
        return result
    }

    /// Tile `index` of `count` along an axis of `length` pixels, or nil when its core is empty.
    private static func span(index: Int, count: Int, length: Int, overlap: Int) -> Span? {
        let coreStart = index * length / count
        let coreEnd = index == count - 1 ? length : (index + 1) * length / count
        guard coreEnd > coreStart else { return nil }
        return Span(
            core: coreStart ..< coreEnd,
            region: max(0, coreStart - overlap) ..< min(length, coreEnd + overlap),
        )
    }

    /// The lines of one tile that the tile owns, mapped from tile-image pixels to page pixels.
    private static func ownedLines(
        _ recognized: [OMRRecognizedLine],
        rows: Span,
        columns: Span,
        scale: Int,
        splitsColumns: Bool,
    ) -> [RasterTextLine] {
        let originX = Double(columns.region.lowerBound)
        let originY = Double(rows.region.lowerBound)
        let factor = Double(scale)
        func toPage(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PixelRect {
            PixelRect(x: originX + x / factor, y: originY + y / factor, width: w / factor, height: h / factor)
        }
        let coreLeft = Double(columns.core.lowerBound)
        let coreRight = Double(columns.core.upperBound)

        var owned: [RasterTextLine] = []
        for line in recognized {
            let rect = toPage(line.x, line.y, line.width, line.height)
            let centerY = rect.y + rect.height / 2
            guard centerY >= Double(rows.core.lowerBound), centerY < Double(rows.core.upperBound) else { continue }
            var characters = line.characters.map {
                RasterTextCharacter(text: $0.text, rect: toPage($0.x, $0.y, $0.width, $0.height))
            }
            guard splitsColumns else {
                owned.append(RasterTextLine(
                    text: line.text, confidence: line.confidence, rect: rect, characters: characters,
                ))
                continue
            }
            let keeps = characters.map { $0.rect.midX >= coreLeft && $0.rect.midX < coreRight }
            let text = keptText(of: line.text, characters: characters, keeps: keeps)
            characters = zip(characters, keeps).filter(\.1).map(\.0)
            guard let union = unionRect(of: characters.map(\.rect)) else { continue }
            owned.append(RasterTextLine(text: text, confidence: line.confidence, rect: union, characters: characters))
        }
        return owned
    }

    /// `lineText` reduced to the kept characters, with one space wherever the recognizer put whitespace between two
    /// of them — `OCRTextGlyphs` splits tokens on that whitespace, so joining the boxes alone would merge syllables.
    ///
    /// `characters` are the line's non-whitespace graphemes in order, minus any the recognizer could not box; a
    /// grapheme that does not match the next box is such a boxless one, has no position, and is dropped.
    private static func keptText(of lineText: String, characters: [RasterTextCharacter], keeps: [Bool]) -> String {
        var text = ""
        var next = 0
        var spaced = false
        for grapheme in lineText {
            if grapheme.isWhitespace {
                spaced = true
                continue
            }
            guard next < characters.count, characters[next].text == String(grapheme) else { continue }
            defer { next += 1 }
            guard keeps[next] else { continue }
            if spaced, !text.isEmpty { text.append(" ") }
            spaced = false
            text.append(grapheme)
        }
        return text
    }

    /// The smallest rect holding every rect in `rects`, or nil when there are none.
    private static func unionRect(of rects: [PixelRect]) -> PixelRect? {
        guard let first = rects.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.maxX
        var maxY = first.maxY
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x)
            minY = min(minY, rect.y)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The `rows` x `columns` window of `bitmap`, resampled `scale`× in both directions with bilinear interpolation.
    private static func upscaledTile(
        of bitmap: GrayBitmap,
        rows: Range<Int>,
        columns: Range<Int>,
        scale: Int,
    ) -> OMRTextImage {
        let stride = bitmap.width
        let srcW = columns.count
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
            let row0 = (rows.lowerBound + y0) * stride + columns.lowerBound
            let row1 = (rows.lowerBound + y1) * stride + columns.lowerBound
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
