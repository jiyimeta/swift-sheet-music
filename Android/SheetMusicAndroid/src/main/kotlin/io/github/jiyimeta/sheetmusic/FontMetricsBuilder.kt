package io.github.jiyimeta.sheetmusic

import android.content.res.AssetManager
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Computes the font-metrics table by measuring the two faces this library
 * draws with — Bravura over SMuFL's private-use area, Edwin over the BMP —
 * and packs the result into the byte format defined at
 * Sources/SheetMusicBridgeCore/FontMetricsTable.swift.
 *
 * Uses `Paint.getTextPath` + `Path.computeBounds(exact=true)` rather than
 * `Paint.getTextBounds`. The TextBounds API returns the **rasterized**
 * pixel-aligned ink rectangle, which on a 1000 pt reference size rounds
 * to integer pixels and can disagree with the geometric path bbox by up
 * to 1 sp at typical staff sizes. The geometric bounds match Apple's
 * `CTFontCreatePathForGlyph().boundingBox`, so the `GlyphAnchor`
 * center→baseline-leading conversion in the bridge produces identical
 * positioning on both platforms.
 *
 * Y convention conversion: Android paths are y-down with baseline at
 * Y=0; the Swift side expects CG-style y-up (matching CGPath). Flip Y
 * by negating bottom/top.
 *
 * Each face record carries its ascent, descent and line gap, read from
 * `Paint.fontMetrics` at the same reference size. `(ascent − descent) / 2` is
 * how the layout engine centres an articulation, fermata or breath mark on its
 * baseline; before SMFT v3 the Swift provider had no such fields to consult and
 * fell back to a stub's 0.85 / 0.25 em, which put those glyphs 1.2 sp below
 * where Apple draws them. Bravura declares ascender 2012 and descender −2012 at
 * 1000 upm in hhea, OS/2 typo and win alike, so the pair is the same whichever
 * table Skia reads — and the same CoreText reports, which is what makes the
 * three platforms agree.
 *
 * v4 adds Edwin for the same reason, one level down: a table with no text face
 * left every advance in a lyric, harmony or rehearsal-mark frame coming from
 * `StubFontMetricsProvider.advanceEm`'s bucket estimate (digits 0.5, uppercase
 * 0.65, lowercase 0.5, punctuation 0.3 em) and every text row positioned off
 * 0.85 / 0.25 em with no line gap, against Edwin's measured 0.737 / 0.263 /
 * 0.200.
 *
 * Cost: each face's `cmap` is parsed once, and only the codepoints it actually
 * maps are measured — ~3.4k paths for Bravura and ~0.9k for Edwin. Build the
 * result once per process and hand it straight to
 * `SheetMusicJNI.nativeInstallSMuFLMetrics`.
 */
object FontMetricsBuilder {

    private const val MAGIC = 0x53_4D_46_54
    // Keep in lockstep with `FontMetricsTable.version` on the Swift side.
    // v2 swapped the hand-written byte cursor for `@WireFormat`; layout is
    // byte-identical for any non-negative glyph count. v3 added `f32 ascent`
    // and `f32 descent` between `referenceSize` and the glyph count. v4 made
    // the table carry several faces: the vertical metrics moved into a
    // per-face record, `f32 leading` joined them, and the face's name
    // precedes them as a length-prefixed UTF-8 string.
    private const val VERSION = 4
    private const val REFERENCE_SIZE = 1000.0

    /** Bravura's BMP PUA range as defined by SMuFL. */
    private const val PUA_START = 0xE000
    private const val PUA_END = 0xF8FF

    /**
     * Edwin is a text face with no single defining block, so the walk is the
     * whole BMP and the font's own cmap decides what survives.
     * `Tools/GenFontMetrics` walks the identical range.
     */
    private const val TEXT_START = 0x0020
    private const val TEXT_END = 0xFFFF

    private const val SURROGATE_START = 0xD800
    private const val SURROGATE_END = 0xDFFF

    private const val BRAVURA_FACE = "Bravura"
    private const val EDWIN_FACE = "Edwin"

    /**
     * The bold text face's record name. `"<face>-Bold"` is the convention
     * `FontMetricsTable.face(for:)` resolves a bold `LayoutFont` through, so
     * this string and that lookup move together.
     */
    private const val EDWIN_BOLD_FACE = "Edwin-Bold"

    private data class Entry(
        val cp: Int,
        val advance: Float,
        val x: Float,
        val y: Float,
        val w: Float,
        val h: Float,
    )

    private data class Face(
        val name: String,
        val ascent: Float,
        val descent: Float,
        val leading: Float,
        val entries: List<Entry>,
    )

    /**
     * Measures every bundled face the caller's assets carry and packs them into
     * one table.
     *
     * `fonts/Bravura.otf` is required, as it has been since SMFT v1 — without
     * glyph geometry there is no engraving worth doing.
     * `fonts/Edwin-Roman.otf` is OPTIONAL, and deliberately so: it became part
     * of this call in v4, and `Typeface.createFromAsset` throws for an asset
     * that is not there. A host that had only ever needed Bravura would
     * otherwise crash on the first launch after upgrading the AAR, at a call
     * site the README shows without a `try`. Missing, it costs the text face
     * and nothing else — the table still installs and text falls back to the
     * same estimates it used before v4 — which is a far better failure than
     * taking the app down. Add the asset (see this module's README) to get the
     * measured text metrics.
     */
    fun buildTable(assets: AssetManager): ByteArray {
        val faces = mutableListOf<Face>()
        faces += measure(
            assets,
            face = BRAVURA_FACE,
            assetPath = "fonts/Bravura.otf",
            first = PUA_START,
            last = PUA_END,
            keepBlanks = false,
        )
        runCatching {
            measure(
                assets,
                face = EDWIN_FACE,
                assetPath = "fonts/Edwin-Roman.otf",
                first = TEXT_START,
                last = TEXT_END,
                keepBlanks = true,
            )
        }.getOrNull()?.let { faces += it }
        // The bold text face, measured with the SAME synthesis the renderer paints with
        // (`Paint.isFakeBoldText`), not a separate bold font file. MuseScore's own defaults set
        // tempo marks, rehearsal marks and instrument-change text bold, and a rehearsal mark's frame
        // is sized from the measured text — so a table with no bold record puts bold letters through
        // the right-hand edge of a box measured at regular weight.
        //
        // Same `runCatching` as the regular face and for the same reason: Edwin is optional, and a
        // host that ships only Bravura must not crash. A missing bold record simply resolves back to
        // the regular one (`FontMetricsTable.face(for:)`), which is the pre-bold behaviour.
        runCatching {
            measure(
                assets,
                face = EDWIN_BOLD_FACE,
                assetPath = "fonts/Edwin-Roman.otf",
                first = TEXT_START,
                last = TEXT_END,
                keepBlanks = true,
                fakeBold = true,
            )
        }.getOrNull()?.let { faces += it }
        return encode(faces)
    }

    /**
     * @param keepBlanks whether a mapped glyph with no ink is worth an entry.
     * A text face's blanks carry the advances that space out a lyric, so
     * dropping them would send every space back to the stub's 0.3 em guess; a
     * SMuFL face has no such glyphs, and skipping them keeps the table to the
     * glyphs that draw.
     */
    private fun measure(
        assets: AssetManager,
        face: String,
        assetPath: String,
        first: Int,
        last: Int,
        keepBlanks: Boolean,
        fakeBold: Boolean = false,
    ): Face {
        // Which codepoints this face actually has comes from the file's own
        // `cmap`, NOT from `Paint`. Nothing in `Paint` can answer it: measured
        // on a Pixel 8a, `hasGlyph` returns true for CJK, kana and emoji on a
        // `Typeface.createFromAsset(Edwin)` paint, because it consults the
        // system fallback chain — a BMP walk driven by it stored 55,093 entries
        // instead of Edwin's 869, every one of them measuring whatever font
        // Android would have substituted. `getTextWidths` and `getTextPath`
        // substitute the same way, so the membership test has to come from
        // outside `Paint` and the measurements have to be restricted to what it
        // returns. It matters for the SMuFL face too: the PUA walk picked up one
        // codepoint Bravura does not have (3411 against CoreText's 3410) for the
        // same reason.
        val coverage = cmapCodepoints(assets, assetPath)
        val tf = Typeface.createFromAsset(assets, assetPath)
        val paint = Paint().apply {
            typeface = tf
            textSize = REFERENCE_SIZE.toFloat()
            isAntiAlias = true
            // Algorithmic emboldening, the same knob `ScoreCanvas` sets when it paints a
            // `setTextStyle` bold run. Measuring the synthesis rather than a real bold font file is
            // the point: what the table reports has to be what the renderer draws, and Edwin ships
            // as a single Roman face here.
            isFakeBoldText = fakeBold
        }
        // `Paint.FontMetrics` is y-down: ascent is negative (above the
        // baseline), descent positive. The Swift side wants both as positive
        // magnitudes, the way `FontMetricsProvider` reports them. `leading` is
        // already the extra gap BETWEEN lines, which is the same quantity
        // `CTFontGetLeading` reports.
        val fontMetrics = paint.fontMetrics

        val widths = FloatArray(2)
        val path = Path()
        val rectF = RectF()

        val entries = ArrayList<Entry>(2048)
        for (cp in first..last) {
            if (cp in SURROGATE_START..SURROGATE_END) continue
            if (cp !in coverage) continue
            val s = String(intArrayOf(cp), 0, 1)
            val n = paint.getTextWidths(s, widths)
            val advance = if (n < 1) 0f else widths[0]
            path.reset()
            paint.getTextPath(s, 0, s.length, 0f, 0f, path)
            // exact=true: traverse the actual control polygon, not the
            // conservative fast bounds.
            path.computeBounds(rectF, true)
            val inked = !rectF.isEmpty
            if (keepBlanks) {
                if (advance <= 0f && !inked) continue
            } else {
                if (advance <= 0f || !inked) continue
            }
            // CG-style bbox: x grows right, y grows up. Path coords are
            // y-down with baseline at y=0, so y-up.minY = -rectF.bottom.
            // A mapped-but-blank glyph stores a zero box; the reader skips
            // zero-area boxes when it unions ink.
            val bx = if (inked) rectF.left else 0f
            val by = if (inked) -rectF.bottom else 0f
            val bw = if (inked) rectF.width() else 0f
            val bh = if (inked) rectF.height() else 0f
            entries.add(Entry(cp, advance, bx, by, bw, bh))
        }

        return Face(
            name = face,
            ascent = -fontMetrics.ascent,
            descent = fontMetrics.descent,
            leading = fontMetrics.leading,
            entries = entries,
        )
    }

    /**
     * The BMP codepoints an OpenType file's own `cmap` maps to a real glyph.
     *
     * Hand-parsed from the asset bytes because the platform offers no way to
     * ask a `Typeface` what it covers — see the note in [measure] — and because
     * `android.graphics.fonts.Font`, which would expose the buffer, is API 29
     * while this module supports 28. Only the two encodings that matter here
     * are read: Windows BMP (3, 1) format 4, and Windows full-repertoire
     * (3, 10) format 12, preferring the latter. Supplementary planes are
     * ignored, since both walks are BMP-only.
     */
    private fun cmapCodepoints(assets: AssetManager, assetPath: String): Set<Int> {
        val bytes = assets.open(assetPath).use { it.readBytes() }
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)

        fun u8(at: Int) = buf.get(at).toInt() and 0xFF
        fun u16(at: Int) = ((u8(at) shl 8) or u8(at + 1))
        fun s16(at: Int) = u16(at).toShort().toInt()
        fun u32(at: Int) = (u16(at).toLong() shl 16) or u16(at + 2).toLong()

        val numTables = u16(4)
        var cmapOffset = -1
        for (i in 0 until numTables) {
            val record = 12 + i * 16
            val tag = String(bytes, record, 4, Charsets.US_ASCII)
            if (tag == "cmap") {
                cmapOffset = u32(record + 8).toInt()
                break
            }
        }
        require(cmapOffset >= 0) { "$assetPath has no cmap table" }

        // Pick the best subtable: (3,10) beats (3,1) beats anything else we can
        // read at all.
        var best = -1
        var bestRank = -1
        val subtableCount = u16(cmapOffset + 2)
        for (i in 0 until subtableCount) {
            val record = cmapOffset + 4 + i * 8
            val platform = u16(record)
            val encoding = u16(record + 2)
            val rank = when {
                platform == 3 && encoding == 10 -> 3
                platform == 3 && encoding == 1 -> 2
                platform == 0 -> 1
                else -> 0
            }
            if (rank > bestRank) {
                bestRank = rank
                best = cmapOffset + u32(record + 4).toInt()
            }
        }
        require(best >= 0) { "$assetPath has no readable cmap subtable" }

        val covered = HashSet<Int>(4096)
        when (val format = u16(best)) {
            4 -> {
                val segCount = u16(best + 6) / 2
                val endCodes = best + 14
                val startCodes = endCodes + segCount * 2 + 2
                val idDeltas = startCodes + segCount * 2
                val idRangeOffsets = idDeltas + segCount * 2
                for (seg in 0 until segCount) {
                    val end = u16(endCodes + seg * 2)
                    val start = u16(startCodes + seg * 2)
                    if (start > end) continue
                    val delta = s16(idDeltas + seg * 2)
                    val rangeOffsetAt = idRangeOffsets + seg * 2
                    val rangeOffset = u16(rangeOffsetAt)
                    for (cp in start..end) {
                        if (cp == 0xFFFF) continue
                        val glyph = if (rangeOffset == 0) {
                            (cp + delta) and 0xFFFF
                        } else {
                            val at = rangeOffsetAt + rangeOffset + (cp - start) * 2
                            val raw = u16(at)
                            if (raw == 0) 0 else (raw + delta) and 0xFFFF
                        }
                        if (glyph != 0) covered.add(cp)
                    }
                }
            }

            12 -> {
                val groupCount = u32(best + 12).toInt()
                for (g in 0 until groupCount) {
                    val record = best + 16 + g * 12
                    val start = u32(record).toInt()
                    val end = u32(record + 4).toInt()
                    val startGlyph = u32(record + 8).toInt()
                    for (cp in start..minOf(end, 0xFFFF)) {
                        if (startGlyph + (cp - start) != 0) covered.add(cp)
                    }
                }
            }

            else -> throw IllegalStateException("$assetPath: unsupported cmap format $format")
        }
        return covered
    }

    private fun encode(faces: List<Face>): ByteArray {
        val header = 4 + 4 + 8 + 4
        val perGlyph = 4 + 4 + 4 + 4 + 4 + 4
        var size = header
        val names = faces.map { it.name.toByteArray(Charsets.UTF_8) }
        for ((index, face) in faces.withIndex()) {
            size += 4 + names[index].size + 4 + 4 + 4 + 4
            size += face.entries.size * perGlyph
        }
        val buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(MAGIC)
        buf.putInt(VERSION)
        buf.putDouble(REFERENCE_SIZE)
        buf.putInt(faces.size)
        for ((index, face) in faces.withIndex()) {
            buf.putInt(names[index].size)
            buf.put(names[index])
            buf.putFloat(face.ascent)
            buf.putFloat(face.descent)
            buf.putFloat(face.leading)
            buf.putInt(face.entries.size)
            for (e in face.entries) {
                buf.putInt(e.cp)
                buf.putFloat(e.advance)
                buf.putFloat(e.x)
                buf.putFloat(e.y)
                buf.putFloat(e.w)
                buf.putFloat(e.h)
            }
        }
        return buf.array()
    }
}
