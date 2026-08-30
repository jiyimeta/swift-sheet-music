package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.MidiControlChange

/**
 * Decodes the `(controller, value)` byte pairs the native bridge answers with.
 *
 * Hand-written rather than generated because the payload is a flat byte array with no field names to get wrong:
 * two bytes per message, in the order they are to be sent. An odd trailing byte would mean a truncated read, and
 * is dropped rather than guessed at.
 */
internal object MidiControlChangeCodec {
    fun decode(bytes: ByteArray): List<MidiControlChange> =
        (0 until bytes.size / 2).map { i ->
            MidiControlChange(
                controller = bytes[i * 2].toInt() and 0xFF,
                value = bytes[i * 2 + 1].toInt() and 0xFF,
            )
        }
}
