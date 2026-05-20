package io.github.jiyimeta.sheetmusic

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Score-level metadata surfaced from the Swift `Score.metaTags`
 * dictionary via [SheetMusicJNI.nativeScoreMetadata]. Both fields are
 * empty strings when the underlying metaTag is absent.
 */
data class ScoreMetadata(
    val title: String,
    val composer: String,
) {
    companion object {
        /**
         * Fetch metadata for [scoreHandle] in one JNI round trip.
         * Returns `null` for an unknown / released handle (the JNI
         * symbol returns an empty array in that case).
         */
        fun fetch(scoreHandle: Long): ScoreMetadata? =
            decode(SheetMusicJNI.nativeScoreMetadata(scoreHandle))

        /**
         * Decode the wire format
         * `[titleLen:I32 LE][titleBytes][composerLen:I32 LE][composerBytes]`.
         * Returns `null` for an empty input (e.g. unknown handle).
         */
        internal fun decode(bytes: ByteArray): ScoreMetadata? {
            if (bytes.isEmpty()) return null
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            if (buf.remaining() < 4) return null
            val titleLen = buf.int
            if (titleLen < 0 || buf.remaining() < titleLen) return null
            val titleBytes = ByteArray(titleLen)
            buf.get(titleBytes)
            if (buf.remaining() < 4) return null
            val composerLen = buf.int
            if (composerLen < 0 || buf.remaining() < composerLen) return null
            val composerBytes = ByteArray(composerLen)
            buf.get(composerBytes)
            return ScoreMetadata(
                title = String(titleBytes, Charsets.UTF_8),
                composer = String(composerBytes, Charsets.UTF_8),
            )
        }
    }
}
