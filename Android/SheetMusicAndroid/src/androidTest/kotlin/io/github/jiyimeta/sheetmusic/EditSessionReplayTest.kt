package io.github.jiyimeta.sheetmusic

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SP0/SP1's acceptance test: the same `EditReplayScript.standard` editing steps that `EditReplayGoldenTests.swift`
 * runs on the host, relayed here from Kotlin across the JNI boundary into a second, separately-linked image of the
 * engine. Equal fingerprints at every step is the claim the whole Android editing design rests on — that relaying
 * an intent's bytes keeps two copies of a score identical.
 *
 * Kotlin never builds an intent. The `step-N.bin` assets under `assets/editReplay/` are pre-encoded by the Swift
 * host test (`EditIntentCodec` on the wire format Task 5 produced) and committed alongside `goldens.txt` and a copy
 * of the `fixture.mscx` fixture (`EditingFixtures.replayFixture()`, encoded via `MSCXEncoder`); this test is a
 * courier that relays those opaque bytes to [SheetMusicJNI], exactly what a real edit session does — the host's
 * Swift core is always the one that encodes an intent, Kotlin only ever relays the result.
 *
 * Whether a step is an edit or an undo is derived from asset presence: index `i` has a `step-i.bin` when
 * `EditReplayGoldenTests.swift` applied an intent there, and has none when that step was an undo. That is a real,
 * if implicit, coupling between the two sides — it is not part of the wire format itself, just this test harness's
 * own convention for telling the two step kinds apart from a directory listing. `EditReplayScript.standard`
 * represents "redo" the same way — undo, then a normal apply step that happens to re-encode the same intent — so
 * this harness never needed a third convention for it.
 */
@RunWith(AndroidJUnit4::class)
class EditSessionReplayTest {
    companion object {
        /** Must track `EditReplayScript.standard(staff:).count` on the host exactly — see the assertion below. */
        private const val EXPECTED_STEP_COUNT = 20
    }

    @Test
    fun replayMatchesHostGoldens() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val assetNames = context.assets.list("editReplay")!!.toSet()

        val goldensText = context.assets.open("editReplay/goldens.txt").bufferedReader().use { it.readText() }
        val expected = goldensText.trim().split("\n").map { it.trim().toLong() }
        // Asserted explicitly rather than derived from `expected.size`, so a goldens.txt truncated by a bad record
        // run shrinks this test's expectations silently instead of failing it outright.
        assertEquals(
            "goldens.txt should hold one fingerprint per step plus the initial one",
            EXPECTED_STEP_COUNT + 1,
            expected.size,
        )
        val stepCount = EXPECTED_STEP_COUNT

        val bytes = context.assets.open("editReplay/fixture.mscx").use { it.readBytes() }
        val handle = SheetMusicJNI.nativeLoadScore(bytes)
        assertTrue("score failed to parse", handle != 0L)
        try {
            assertTrue(SheetMusicJNI.nativeBeginEditSession(handle))
            val actual = mutableListOf(SheetMusicJNI.nativeScoreFingerprint(handle))
            for (i in 0 until stepCount) {
                // No step-i.bin asset means step i was an undo on the host — see this class's doc comment.
                val fileName = "step-$i.bin"
                if (assetNames.contains(fileName)) {
                    val intentBytes = context.assets.open("editReplay/$fileName").use { it.readBytes() }
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

    @Test
    fun versionStampIsNonZero() {
        assertTrue(SheetMusicJNI.nativeEngineVersionStamp() != 0L)
    }
}
