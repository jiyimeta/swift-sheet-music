package com.example.sheetmusic.cursor

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Bounding rectangle (document/mm coordinates) returned by nativeCursorFrame. */
data class CursorFrame(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
) {
    companion object {
        const val FORMAT_VERSION = 1

        /**
         * Decodes the 34-byte CursorFrame wire format.
         *
         * Returns null for empty input, which signals "cursor did not resolve"
         * (e.g. stale ID after a re-layout).
         *
         * Wire format (little-endian):
         *   u16 version (= 1)
         *   i64 xMicros        // coordinate * 1e6, rounded
         *   i64 yMicros
         *   i64 widthMicros
         *   i64 heightMicros
         */
        fun decode(bytes: ByteArray): CursorFrame? {
            if (bytes.isEmpty()) return null
            require(bytes.size >= 34) { "CursorFrame payload too short: ${bytes.size}" }
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val version = buf.short.toInt() and 0xFFFF
            require(version == FORMAT_VERSION) {
                "CursorFrame version mismatch: $version (expected $FORMAT_VERSION)"
            }
            val x = buf.long.toDouble() / 1_000_000.0
            val y = buf.long.toDouble() / 1_000_000.0
            val w = buf.long.toDouble() / 1_000_000.0
            val h = buf.long.toDouble() / 1_000_000.0
            return CursorFrame(x, y, w, h)
        }
    }
}
