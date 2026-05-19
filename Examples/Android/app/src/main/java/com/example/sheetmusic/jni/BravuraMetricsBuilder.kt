package com.example.sheetmusic.jni

import android.content.res.AssetManager
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Computes a SMuFL glyph-metrics table by measuring every codepoint in
 * Bravura's BMP private-use area with Android `Paint.getTextBounds` and
 * `Paint.measureText`, then packs the result into the byte format
 * defined at Sources/SheetMusicAndroidJNI/SMuFLMetricsTable.swift.
 *
 * Y convention conversion: Android Paint returns ink bounds where Y
 * increases downward and the baseline is at Y=0. The Swift side expects
 * CG-style (Y increases upward), matching `CGPath.boundingBox` from
 * CoreText. We flip Y by negating bottom/top.
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
        val rect = Rect()
        val widths = FloatArray(2)

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
            paint.getTextBounds(s, 0, s.length, rect)
            // CG-style bbox: x grows right, y grows up.
            val bx = rect.left.toFloat()
            val by = (-rect.bottom).toFloat()
            val bw = (rect.right - rect.left).toFloat()
            val bh = (rect.bottom - rect.top).toFloat()
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
