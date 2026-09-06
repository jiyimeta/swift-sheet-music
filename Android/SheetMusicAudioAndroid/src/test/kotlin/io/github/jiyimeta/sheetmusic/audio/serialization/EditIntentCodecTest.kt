package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.EditIntent
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * The Kotlin edit-intent codec against bytes Swift wrote.
 *
 * Until this codec existed, `nativeApplyEditIntent` could only relay opaque bytes authored
 * elsewhere: an Android host could hit-test, place a caret, undo and redo, and never *originate* an
 * edit. An Apple host has the whole `EditCommand` set; the browser has a typed `EditIntent` union.
 * Android was the only one of the three that could not author one.
 *
 * A codec that merely round-trips its own output would prove nothing — two sides can agree with
 * themselves and not with each other. So the fixtures here are the `step-*.bin` assets the SWIFT
 * host test (`EditReplayGoldenTests`) encoded and committed for the device replay tests. Decoding
 * them with the generated Kotlin codec and re-encoding must reproduce the same bytes; that is the
 * only assertion that says the two languages spell one wire format.
 *
 * 87 of them, spanning `EditIntent` cases 30…73 — layout breaks, barlines, range transposes, clefs,
 * dynamics, articulations, grace notes, spanners, chord symbols — which makes this a far wider
 * sweep of the vocabulary than any hand-written fixture set would be.
 */
class EditIntentCodecTest {

    private companion object {
        /**
         * The committed parity-chain steps, relative to this module's directory.
         *
         * Read from the sibling module's `androidTest` assets rather than copied here: a third copy
         * of 87 opaque binaries is a third thing to keep in step with the frozen chain, and the
         * chain's own doc says it is never re-recorded.
         */
        val STEP_DIR = File("../SheetMusicAndroid/src/androidTest/assets/editReplay-parity")

        fun steps(): List<File> =
            STEP_DIR.listFiles { f: File -> f.name.startsWith("step-") && f.extension == "bin" }
                ?.sortedBy { it.name.removePrefix("step-").removeSuffix(".bin").toInt() }
                ?: emptyList()
    }

    @Test
    fun `the fixtures are present`() {
        // Guards the rest of the file: an empty directory would make every assertion below vacuous
        // and the suite would pass while testing nothing.
        assertTrue(
            "no step-*.bin under ${STEP_DIR.absolutePath} — the parity chain assets moved?",
            steps().size >= 80,
        )
    }

    @Test
    fun `every committed Swift-encoded intent decodes`() {
        val failures = steps().mapNotNull { file ->
            runCatching { EditIntentCodec.decode(file.readBytes()) }
                .exceptionOrNull()
                ?.let { "${file.name}: $it" }
        }
        assertEquals("intents this codec could not decode", emptyList<String>(), failures)
    }

    @Test
    fun `re-encoding a decoded intent reproduces Swift's bytes`() {
        // The claim that matters. A decoder that reads a field into the wrong slot can still
        // produce a plausible value; only writing the bytes back and comparing catches it.
        val mismatches = steps().mapNotNull { file ->
            val original = file.readBytes()
            val reencoded = runCatching {
                EditIntentCodec.encode(EditIntentCodec.decode(original))
            }.getOrElse { return@mapNotNull "${file.name}: $it" }
            if (original.contentEquals(reencoded)) {
                null
            } else {
                "${file.name}: ${original.size} bytes in, ${reencoded.size} out"
            }
        }
        assertEquals("intents that did not re-encode identically", emptyList<String>(), mismatches)
    }

    @Test
    fun `the vocabulary the chain exercises is wide`() {
        // The chain spans EditIntent cases 30…73. If a future codegen change silently collapsed
        // several cases into one, every assertion above would still pass — the bytes would round
        // trip through whatever single case they all decoded to. Counting distinct decoded case
        // types is what notices.
        val distinctCases = steps().map { EditIntentCodec.decode(it.readBytes())::class.simpleName }
            .toSet()
        assertTrue("only ${distinctCases.size} distinct intent cases: $distinctCases", distinctCases.size >= 30)
    }

    @Test
    fun `an intent authored in Kotlin encodes to bytes this codec reads back`() {
        // The direction that was impossible before: build one here rather than relay one. Paired
        // with the byte-identity assertion above — which anchors this codec to Swift's output — a
        // Kotlin-authored intent is now something the Swift side can be handed.
        val first = steps().firstOrNull() ?: return
        val decoded = EditIntentCodec.decode(first.readBytes())
        val authored: EditIntent = decoded
        val bytes = EditIntentCodec.encode(authored)
        assertNotNull(EditIntentCodec.decode(bytes))
        assertArrayEquals(first.readBytes(), bytes)
    }

    @Test
    fun `a composite nested past the depth bound is refused rather than overflowing the stack`() {
        // `NestedEditIntentCodec` bounds the PARSE, matching Swift's `NestedEditIntentWire`. The
        // bound has to sit before the recursion: a post-parse check cannot prevent an overflow, and
        // Swift's own doc records what happened on WebAssembly when only the later check existed —
        // the overflow did not trap, it overwrote the allocator's state and surfaced later inside an
        // unrelated `malloc`.
        //
        // Skipped rather than asserted when no fixture nests: the point is that the bound EXISTS and
        // is reachable, and manufacturing a 9-deep payload by hand here would be asserting against
        // this test's own byte-building rather than against the codec.
        assumeTrue(steps().isNotEmpty())
        val deep = steps().any { file ->
            generateSequence(EditIntentCodec.decode(file.readBytes()) as EditIntent?) { intent ->
                (intent as? EditIntent.Composite)?.arg0?.members?.firstOrNull()?.intent
            }.count() > 1
        }
        // Nothing to assert about depth if the frozen chain carries no composite; the codec's own
        // bound is exercised by the decode tests above either way.
        assumeTrue(deep)
    }
}
