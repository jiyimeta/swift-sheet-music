package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.RehearsalMarkEntry
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes the `[RehearsalMarkEntry]` blob produced by Swift's
 * `RehearsalMarkCodec.encode(_:)` (in `Sources/SheetMusicAndroidJNI/Audio/`),
 * surfaced by [io.github.jiyimeta.sheetmusic.SheetMusicJNI.nativeRehearsalMarks].
 *
 * Unlike the wirelet TLV codecs, the Swift producer here hand-rolls fixed-width
 * **little-endian** fields (the same family as `FontMetricsTable` /
 * `FontMetricsBuilder`), so this reader is hand-written field-for-field rather
 * than going through `BinaryReader`:
 *
 * ```
 * i32 count
 * count × {
 *   i32  textByteCount
 *   text UTF-8 bytes        (textByteCount bytes)
 *   f64  fraction           (IEEE 754 bit pattern)
 *   i32  cursorByteCount
 *   cursor bytes            (cursorByteCount bytes — a ScoreCursorCodec payload)
 * }
 * ```
 *
 * The cursor sub-blob is opaque to this codec: it is the exact `ScoreCursorCodec`
 * wire payload (wirelet TLV framing), so it is delegated to [ScoreCursorCodec.decode].
 *
 * An empty / absent list still carries the `i32 count == 0` header, so an unknown
 * native handle decodes to an empty list rather than throwing.
 */
object RehearsalMarkCodec {
    fun decode(bytes: ByteArray): List<RehearsalMarkEntry> {
        if (bytes.isEmpty()) return emptyList()
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val count = buf.int
        val out = ArrayList<RehearsalMarkEntry>(maxOf(0, count))
        repeat(count) {
            val textLen = buf.int
            val textBytes = ByteArray(textLen)
            buf.get(textBytes)
            val text = textBytes.toString(Charsets.UTF_8)

            val fraction = buf.double

            val cursorLen = buf.int
            val cursorBytes = ByteArray(cursorLen)
            buf.get(cursorBytes)
            val cursor = ScoreCursorCodec.decode(cursorBytes)

            out.add(RehearsalMarkEntry(text = text, fraction = fraction, cursor = cursor))
        }
        return out
    }
}
