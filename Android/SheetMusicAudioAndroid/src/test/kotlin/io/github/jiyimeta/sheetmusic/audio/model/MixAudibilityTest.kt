package io.github.jiyimeta.sheetmusic.audio.model

import io.github.jiyimeta.sheetmusic.audio.model.MixAudibilityTable.StripState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [MixAudibility] decides mute / solo exactly as the Apple engine's `MixerChannel.isSilenced(soloing:)` under
 * `Collection<MixerChannel>.isSoloing` does. The expected values are [MixAudibilityTable]'s, which name the Swift test
 * pinning the same table.
 */
class MixAudibilityTest {
    @Test
    fun theTableCoversEveryCombinationOfTwoStrips() {
        val covered = MixAudibilityTable.rows.map { it.strip0 to it.strip1 }.toSet()
        val all = StripState.entries.flatMap { a -> StripState.entries.map { b -> a to b } }.toSet()
        assertEquals(16, MixAudibilityTable.rows.size)
        assertEquals(all, covered)
    }

    @Test
    fun everyStripIsSilencedAsTheAppleRuleSays() {
        for (row in MixAudibilityTable.rows) {
            val strips = listOf(strip(0, row.strip0), strip(1, row.strip1))
            val soloing = MixAudibility.isSoloing(strips)
            assertEquals("strip 0 in $row", row.silent0, MixAudibility.isSilenced(strips[0], soloing))
            assertEquals("strip 1 in $row", row.silent1, MixAudibility.isSilenced(strips[1], soloing))
        }
    }

    /**
     * The case the live engine used to get wrong, pinned on its own: it engaged solo only for a soloed strip that was
     * NOT muted, so muting the one soloed strip let every other strip back in. Apple counts it.
     */
    @Test
    fun aMutedAndSoloedStripEngagesSolo() {
        val strips = listOf(strip(0, StripState.MUTED_AND_SOLOED), strip(1, StripState.PLAIN))
        assertTrue(MixAudibility.isSoloing(strips))
        assertTrue("the muted + soloed strip stays silent", MixAudibility.isSilenced(strips[0], soloing = true))
        assertTrue("the plain strip is shut out by the solo", MixAudibility.isSilenced(strips[1], soloing = true))
    }

    private fun strip(index: Int, state: StripState) = MixerChannel(
        partIndex = index,
        ordinal = 0,
        liveChannel = index,
        displayName = "Staff ${index + 1}",
        isMuted = state.isMuted,
        isSoloed = state.isSoloed,
    )
}
