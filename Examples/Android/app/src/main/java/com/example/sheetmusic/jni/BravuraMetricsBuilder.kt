package com.example.sheetmusic.jni

import android.content.res.AssetManager
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Computes a SMuFL glyph-metrics table by walking every codepoint in
 * Bravura's BMP private-use area, then packs the result into the byte
 * format defined at Sources/SheetMusicAndroidJNI/SMuFLMetricsTable.swift.
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
 */
object BravuraMetricsBuilder {

    private const val MAGIC = 0x53_4D_46_54
    private const val VERSION = 1
    private const val REFERENCE_SIZE = 1000.0

    /** Bravura's BMP PUA range as defined by SMuFL. */
    private const val PUA_START = 0xE000
    private const val PUA_END = 0xF8FF

    fun buildTable(assets: AssetManager): ByteArray {
        val tf = Typeface.createFromAsset(assets, "fonts/Bravura.otf")
        val paint = Paint().apply {
            typeface = tf
            textSize = REFERENCE_SIZE.toFloat()
            isAntiAlias = true
        }
        val widths = FloatArray(2)
        val path = Path()
        val rectF = RectF()

        // Pre-walk to find defined codepoints.
        data class Entry(
            val cp: Int, val advance: Float,
            val x: Float, val y: Float, val w: Float, val h: Float,
        )
        val entries = ArrayList<Entry>(2048)
        for (cp in PUA_START..PUA_END) {
            val s = String(intArrayOf(cp), 0, 1)
            val n = paint.getTextWidths(s, widths)
            if (n < 1 || widths[0] <= 0f) continue
            path.reset()
            paint.getTextPath(s, 0, s.length, 0f, 0f, path)
            // exact=true: traverse the actual control polygon, not the
            // conservative fast bounds.
            path.computeBounds(rectF, true)
            if (rectF.isEmpty) continue
            // CG-style bbox: x grows right, y grows up. Path coords are
            // y-down with baseline at y=0, so y-up.minY = -rectF.bottom.
            val bx = rectF.left
            val by = -rectF.bottom
            val bw = rectF.width()
            val bh = rectF.height()
            entries.add(Entry(cp, widths[0], bx, by, bw, bh))
        }

        val header = 4 + 4 + 8 + 4
        val perGlyph = 4 + 4 + 4 + 4 + 4 + 4
        val buf = ByteBuffer
            .allocate(header + entries.size * perGlyph)
            .order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(MAGIC)
        buf.putInt(VERSION)
        buf.putDouble(REFERENCE_SIZE)
        buf.putInt(entries.size)
        for (e in entries) {
            buf.putInt(e.cp)
            buf.putFloat(e.advance)
            buf.putFloat(e.x)
            buf.putFloat(e.y)
            buf.putFloat(e.w)
            buf.putFloat(e.h)
        }
        return buf.array()
    }
}
