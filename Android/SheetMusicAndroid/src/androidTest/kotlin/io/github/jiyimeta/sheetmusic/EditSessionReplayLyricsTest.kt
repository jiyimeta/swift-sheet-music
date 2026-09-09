package io.github.jiyimeta.sheetmusic

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * [EditSessionReplayTest] / [EditSessionReplayParityTest]'s twin for the macOS score-text-entry project's chain
 * (`ReplayChain.lyrics` on the host): fifteen `EditReplayScript.lyrics` steps covering both intents this project
 * appended — `setLyricSyllables` (`EditIntent` case 74) in steps 1…6 and `setTextVisible` (case 75) in steps
 * 7…15 — relayed from Kotlin across the JNI boundary into a second, separately-linked image of the engine. Equal
 * fingerprints at every step is the claim the whole Android editing design rests on: relaying an intent's bytes
 * keeps two copies of a score identical.
 *
 * Three of the four text kinds case 75 addresses were invisible to `Score.stableFingerprint` until it landed, so
 * this chain would have passed while one image failed to apply a hide. `ScoreFingerprint.swift`'s blind-spot list
 * names the fields that were brought into the walk to close that.
 *
 * A third class rather than a parameterized one, for the same reason [EditSessionReplayParityTest] is its own
 * class and not folded into [EditSessionReplayTest]: the chains share nothing but this procedure, and a failure
 * that names the class says immediately which chain drifted. This chain is a THIRD `ReplayChain` rather than a
 * fifth group appended to `ReplayChain.parity`, because that chain is frozen — see `ReplayChain.parity`'s own doc
 * comment on the host.
 *
 * Kotlin never builds an intent. The `step-N.bin` assets under `assets/editReplay-lyrics/` are pre-encoded by the
 * Swift host test (`EditReplayGoldenTests.swift`, run over `ReplayChain.lyrics`) and committed alongside
 * `goldens.txt` and a copy of the `fixture.mscx` fixture (`EditingFixtures.twoConsecutiveC4Chords()`, encoded via
 * `MSCXEncoder`); this test is a courier that relays those opaque bytes to [SheetMusicJNI], exactly what a real
 * edit session does — the host's Swift core is always the one that encodes an intent, Kotlin only ever relays the
 * result.
 *
 * Whether a step is an edit or an undo is derived from asset presence: index `i` (0-based, this asset numbering)
 * has a `step-i.bin` when the host applied an intent there, and has none when that step was an undo — indices 2
 * and 8 in this chain, the undos of the hyphenated two-chord write and of the rehearsal-mark hide, each of which
 * the following step re-applies. That is a real, if implicit, coupling between the two sides; it is not part of
 * the wire format itself, just this harness's own convention for telling the two step kinds apart from a
 * directory listing.
 */
@RunWith(AndroidJUnit4::class)
class EditSessionReplayLyricsTest {
    companion object {
        /** Must track `EditReplayScript.lyrics(staff:).count` on the host exactly — see the assertion below. */
        private const val EXPECTED_STEP_COUNT = 15

        private const val ASSET_DIR = "editReplay-lyrics"
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
