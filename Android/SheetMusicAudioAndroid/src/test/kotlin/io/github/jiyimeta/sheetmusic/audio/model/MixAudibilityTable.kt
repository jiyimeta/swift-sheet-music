package io.github.jiyimeta.sheetmusic.audio.model

/**
 * Which of two strips is silent, for every combination of their mute / solo buttons — written out by hand to match
 * the Apple rule (`Sources/SheetMusicAudioCore/MixerChannel+Audibility.swift`), not derived from [MixAudibility], so a
 * change to the Kotlin rule has to change this table too.
 *
 * The Swift side pins the same 4 × 4 table: `Tests/SheetMusicTests/PlaybackEngineExportMixTests.swift`
 * (`exportMatchesLive`, crossed over its own `StripState.allCases`), checking that export renders each strip at the
 * CC 7 live playback sends.
 *
 * Shared by [MixAudibilityTest] (the rule itself) and `AndroidPlaybackEngineTest` (live playback and export agree).
 */
internal object MixAudibilityTable {
    /** One strip's mute / solo buttons. */
    enum class StripState(val isMuted: Boolean, val isSoloed: Boolean) {
        PLAIN(isMuted = false, isSoloed = false),
        MUTED(isMuted = true, isSoloed = false),
        SOLOED(isMuted = false, isSoloed = true),
        MUTED_AND_SOLOED(isMuted = true, isSoloed = true),
    }

    data class Row(
        val strip0: StripState,
        val strip1: StripState,
        val silent0: Boolean,
        val silent1: Boolean,
    )

    // Mute wins; any soloed strip — muted or not — engages solo, which silences every strip that is not soloed.
    val rows: List<Row> = listOf(
        Row(StripState.PLAIN, StripState.PLAIN, silent0 = false, silent1 = false),
        Row(StripState.PLAIN, StripState.MUTED, silent0 = false, silent1 = true),
        Row(StripState.PLAIN, StripState.SOLOED, silent0 = true, silent1 = false),
        Row(StripState.PLAIN, StripState.MUTED_AND_SOLOED, silent0 = true, silent1 = true),

        Row(StripState.MUTED, StripState.PLAIN, silent0 = true, silent1 = false),
        Row(StripState.MUTED, StripState.MUTED, silent0 = true, silent1 = true),
        Row(StripState.MUTED, StripState.SOLOED, silent0 = true, silent1 = false),
        Row(StripState.MUTED, StripState.MUTED_AND_SOLOED, silent0 = true, silent1 = true),

        Row(StripState.SOLOED, StripState.PLAIN, silent0 = false, silent1 = true),
        Row(StripState.SOLOED, StripState.MUTED, silent0 = false, silent1 = true),
        Row(StripState.SOLOED, StripState.SOLOED, silent0 = false, silent1 = false),
        Row(StripState.SOLOED, StripState.MUTED_AND_SOLOED, silent0 = false, silent1 = true),

        Row(StripState.MUTED_AND_SOLOED, StripState.PLAIN, silent0 = true, silent1 = true),
        Row(StripState.MUTED_AND_SOLOED, StripState.MUTED, silent0 = true, silent1 = true),
        Row(StripState.MUTED_AND_SOLOED, StripState.SOLOED, silent0 = true, silent1 = false),
        Row(StripState.MUTED_AND_SOLOED, StripState.MUTED_AND_SOLOED, silent0 = true, silent1 = true),
    )
}
