package io.github.jiyimeta.sheetmusic

/**
 * Score-level metadata surfaced from the Swift `Score.metaTags`
 * dictionary via [SheetMusicJNI.nativeScoreMetadata].
 *
 * [title] and [composer] are conveniences for the two keys every host
 * reads; both are empty strings when the underlying metaTag is absent.
 * [tags] is the whole dictionary — `copyright`, `lyricist`, `arranger`,
 * `source` and whatever else the file states — so a host can show a
 * credits line without a second round trip. The two named fields are
 * mirrors of `workTitle` / `composer` inside [tags], not a separate
 * source of truth.
 */
data class ScoreMetadata(
    val title: String,
    val composer: String,
    val tags: Map<String, String> = emptyMap(),
) {
    /** The value for [key], or `null` when the score does not state it. */
    operator fun get(key: String): String? = tags[key]

    /** MuseScore's `copyright` metaTag, or `null`. */
    val copyright: String? get() = tags["copyright"]

    /** MuseScore's `lyricist` metaTag, or `null`. */
    val lyricist: String? get() = tags["lyricist"]

    /** MuseScore's `arranger` metaTag, or `null`. */
    val arranger: String? get() = tags["arranger"]

    companion object {
        /**
         * Fetch metadata for [scoreHandle] in one JNI round trip.
         * Returns `null` for an unknown / released handle (the JNI
         * symbol returns an empty array in that case).
         */
        fun fetch(scoreHandle: Long): ScoreMetadata? {
            val bytes = SheetMusicJNI.nativeScoreMetadata(scoreHandle)
            if (bytes.isEmpty()) return null
            return ScoreMetadataWireCodec.decode(bytes).let { wire ->
                ScoreMetadata(
                    title = wire.title,
                    composer = wire.composer,
                    // associate(), not associateBy()+mapValues(): the Swift side already
                    // key-sorted and de-duplicated this list, so a plain pairing is enough
                    // and keeps the insertion order the encoder chose.
                    tags = wire.metaTags.associate { it.key to it.value },
                )
            }
        }
    }
}
