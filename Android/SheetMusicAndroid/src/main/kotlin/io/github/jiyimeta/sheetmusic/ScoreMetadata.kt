package io.github.jiyimeta.sheetmusic

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
        fun fetch(scoreHandle: Long): ScoreMetadata? {
            val bytes = SheetMusicJNI.nativeScoreMetadata(scoreHandle)
            if (bytes.isEmpty()) return null
            return ScoreMetadataWireCodec.decode(bytes).let {
                ScoreMetadata(title = it.title, composer = it.composer)
            }
        }
    }
}
