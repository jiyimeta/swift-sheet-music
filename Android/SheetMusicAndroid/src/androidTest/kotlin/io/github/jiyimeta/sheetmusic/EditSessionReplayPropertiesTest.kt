package io.github.jiyimeta.sheetmusic

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Replays `ReplayChain.properties`: seventeen accepting steps covering property intents 76…83 through JNI.
 * Like [EditSessionReplayLyricsTest], this relays Swift-recorded opaque bytes into a separately linked engine
 * and compares every fingerprint with the host goldens. Kotlin does not construct the intents here.
 *
 * The script colors a lyric and a notehead, seeds font overrides, applies a set/clear/unchanged font patch,
 * moves the lyric to a free verse, and sets its placement. Font and placement each include undo/reapply.
 * The properties-inspector project appended intents 80…83: the two note flags (cue size, silent playback),
 * one of them undone, then an authored offset set and cleared around an auto-place toggle. Offset and
 * auto-place are deliberately unhashed, so those last three steps leave the fingerprint where it was — they
 * are here to prove the bytes decode and apply on device, not to move the state.
 * No step is expected to fail; refusal behavior belongs in command unit tests until the replay harness
 * supports expected failures across its recorders and consumers.
 *
 * Assets are recorded by `EditReplayGoldenTests` under `editReplay-properties/`: `fixture.mscx`,
 * `goldens.txt`, and fourteen `step-N.bin` files. Zero-based indices 5, 9 and 13 have no binary because they
 * are undos; for 5 and 9 the next step re-applies the same intent bytes. The host's hand-derived fingerprint
 * floor is ten: initial state plus nine new states, with the remaining observations revisiting earlier ones.
 */
@RunWith(AndroidJUnit4::class)
class EditSessionReplayPropertiesTest {
    companion object {
        /** Must track `EditReplayScript.properties(staff:).count` on the host exactly. */
        private const val EXPECTED_STEP_COUNT = 17

        private const val ASSET_DIR = "editReplay-properties"
    }

    @Test
    fun replayMatchesHostGoldens() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val assetNames = context.assets.list(ASSET_DIR)!!.toSet()

        val goldensText = context.assets.open("$ASSET_DIR/goldens.txt").bufferedReader().use { it.readText() }
        val expected = goldensText.trim().split("\n").map { it.trim().toLong() }
        // Keep the expected count independent of the recording so a truncated golden fails explicitly.
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
                // No step-i.bin asset means step i was an undo on the host.
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
