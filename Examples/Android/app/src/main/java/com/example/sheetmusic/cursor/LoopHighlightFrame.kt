package com.example.sheetmusic.cursor

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A single highlight rectangle (mm/document coords). */
data class LoopHighlightFrame(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
)

object LoopHighlightFrameCodec {
    const val FORMAT_VERSION = 1
    private const val HEADER_BYTES = 6 // u16 version + i32 count
    private const val RECT_BYTES = 32 // 4 × i64

    /**
     * Decodes the LoopHighlightRectArray wire format.
     *
     * Empty input returns `emptyList()` (no rects).
     *
     * Wire format (little-endian):
     *   u16 version (= 1)
     *   i32 count
     *   count × { i64 xMicros, i64 yMicros, i64 widthMicros, i64 heightMicros }
     */
    fun decode(bytes: ByteArray): List<LoopHighlightFrame> {
        if (bytes.isEmpty()) return emptyList()
        require(bytes.size >= HEADER_BYTES) {
            "LoopHighlight payload too short: ${bytes.size}"
        }
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val version = buf.short.toInt() and 0xFFFF
        require(version == FORMAT_VERSION) {
            "LoopHighlight version mismatch: $version (expected $FORMAT_VERSION)"
        }
        val count = buf.int
        require(bytes.size >= HEADER_BYTES + count * RECT_BYTES) {
            "LoopHighlight payload truncated: ${bytes.size} for count=$count"
        }
        val out = ArrayList<LoopHighlightFrame>(count)
        repeat(count) {
            val x = buf.long.toDouble() / 1_000_000.0
            val y = buf.long.toDouble() / 1_000_000.0
            val w = buf.long.toDouble() / 1_000_000.0
            val h = buf.long.toDouble() / 1_000_000.0
            out.add(LoopHighlightFrame(x, y, w, h))
        }
        return out
    }
}
