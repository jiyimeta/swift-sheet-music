package io.github.jiyimeta.sheetmusic

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * [EditSessionReplayTest]'s twin for the edit-command parity project's chain (`ReplayChain.parity` on the host):
 * the eighty-eight `EditReplayScript.parity` steps — layout breaks, barlines, repeat barlines, measure repeats and
 * a move-to-voice (`EditIntent` cases 30…34) in steps 1…10, then range transposes, an added interval, a range
 * delete, range accidentals, a range duration and a respell (cases 35…40) in steps 11…19, then two note writes,
 * an element / note / stem / beam hide-and-show and one standing hide (cases 58…61, with 0) in steps 62…72, then
 * a slur, two hairpins, seven line spanners, a volta and three removals (cases 62…72) in steps 73…88, none
 * of which the standard chain encodes — relayed from Kotlin across the JNI boundary into a second,
 * separately-linked image of the engine. Equal fingerprints at every step is the claim the whole Android editing
 * design rests on: relaying an intent's bytes keeps two copies of a score identical.
 *
 * A separate class rather than a parameterized one because the two chains share nothing but this procedure, and a
 * failure that names the class says immediately which chain drifted.
 *
 * Kotlin never builds an intent. The `step-N.bin` assets under `assets/editReplay-parity/` are pre-encoded by the
 * Swift host test (`EditReplayGoldenTests.swift`, run over `ReplayChain.parity`) and committed alongside
 * `goldens.txt` and a copy of the `fixture.mscx` fixture (`EditingFixtures.parityFixture()`, encoded via
 * `MSCXEncoder`); this test is a courier that relays those opaque bytes to [SheetMusicJNI], exactly what a real
 * edit session does — the host's Swift core is always the one that encodes an intent, Kotlin only ever relays the
 * result.
 *
 * Whether a step is an edit or an undo is derived from asset presence: index `i` has a `step-i.bin` when the host
 * applied an intent there, and has none when that step was an undo — indices 6, 17, 36, 52 and 84 in this chain,
 * the undo of the move-to-voice that step 7 then re-applies, the undo of the range delete that step 18 then
 * re-applies, the undo of the marker write that step 37 then re-applies, the undo of the glissando write that step
 * 54 then re-applies, and the undo of the volta that step 86 then re-applies.
 * That is a real, if implicit, coupling between the two sides; it is not part of the wire format itself, just this
 * harness's own convention for telling the two step kinds apart from a directory listing.
 */
@RunWith(AndroidJUnit4::class)
class EditSessionReplayParityTest {
    companion object {
        /** Must track `EditReplayScript.parity(staff:).count` on the host exactly — see the assertion below. */
        private const val EXPECTED_STEP_COUNT = 88

        private const val ASSET_DIR = "editReplay-parity"
    }

    @Test
    fun replayMatchesHostGoldens() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val assetNames = context.assets.list(ASSET_DIR)!!.toSet()

        val goldensText = context.assets.open("$ASSET_DIR/goldens.txt").bufferedReader().use { it.readText() }
        val expected = goldensText.trim().split("\n").map { it.trim().toLong() }
        // Asserted explicitly rather than derived from `expected.size`, so a goldens.txt truncated by a bad record
        // run shrinks this test's expectations silently instead of failing it outright.
        assertEquals(
            "goldens.txt should hold one fingerprint per step plus the initial one",
            EXPECTED_STEP_COUNT + 1,
            expected.size,
        )
        val stepCount = EXPECTED_STEP_COUNT

        val bytes = context.assets.open("$ASSET_DIR/fixture.mscx").use { it.readBytes() }
        val handle = SheetMusicJNI.nativeLoadScore(bytes)
        assertTrue("score failed to parse", handle != 0L)
        try {
            assertTrue(SheetMusicJNI.nativeBeginEditSession(handle))
            val actual = mutableListOf(SheetMusicJNI.nativeScoreFingerprint(handle))
            for (i in 0 until stepCount) {
                // No step-i.bin asset means step i was an undo on the host — see this class's doc comment.
                val fileName = "step-$i.bin"
                if (assetNames.contains(fileName)) {
                    val intentBytes = context.assets.open("$ASSET_DIR/$fileName").use { it.readBytes() }
                    assertTrue(
                        "nativeApplyEditIntent refused step $i",
                        SheetMusicJNI.nativeApplyEditIntent(handle, intentBytes),
                    )
                } else {
                    assertTrue(
                        "nativeEditUndo failed at step $i (no $fileName asset)",
                        SheetMusicJNI.nativeEditUndo(handle),
                    )
                }
                actual.add(SheetMusicJNI.nativeScoreFingerprint(handle))
            }
            assertEquals(expected, actual)
        } finally {
            SheetMusicJNI.nativeEndEditSession(handle)
            SheetMusicJNI.nativeReleaseScore(handle)
        }
    }
}
