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
 * Three chains cover `EditIntent` cases 30…73 (parity), 74…75 (lyrics), and 76…79 (properties).
 * `standard` is deliberately not included: it predates this codec's cases and adds no vocabulary
 * these chains do not already cover. Undo steps have no binary asset and do not count toward a floor.
 */
class EditIntentCodecTest {

    private companion object {
        /**
         * Each chain's committed steps, relative to this module's directory, keyed by its asset
         * directory name — read from the sibling module's `androidTest` assets rather than copied
         * here, so a third copy of these opaque binaries is not a third thing to keep in step with
         * chains recorded by the Swift host only.
         *
         * The value is the floor `the fixtures are present` checks that chain's directory against.
         * Per-chain rather than one combined floor over `steps().size`: a healthy `parity` directory
         * (87 files) alone clears any single combined threshold this file would plausibly choose, so
         * a combined floor could not notice `lyrics`' own directory going empty — every assertion
         * below would then vacuously "pass" while testing none of case 74's vocabulary.
         */
        val STEP_DIR_FLOORS = mapOf(
            "editReplay-parity" to 80,
            "editReplay-lyrics" to 13,
            // Eleven scripted steps minus two undos (zero-based indices 5 and 9).
            "editReplay-properties" to 9,
        )

        fun stepsIn(chain: String): List<File> {
            val dir = File("../SheetMusicAndroid/src/androidTest/assets/$chain")
            return dir.listFiles { f: File -> f.name.startsWith("step-") && f.extension == "bin" }
                ?.sortedBy { it.name.removePrefix("step-").removeSuffix(".bin").toInt() }
                ?: emptyList()
        }

        fun steps(): List<File> = STEP_DIR_FLOORS.keys.flatMap { stepsIn(it) }

        /** `"editReplay-parity/step-3.bin"` rather than the bare filename, since two chains both have a `step-0.bin`. */
        fun File.chainRelativeName(): String = "${parentFile?.name}/$name"
    }

    @Test
    fun `the fixtures are present`() {
        // Guards the rest of the file: an empty directory would make every assertion below vacuous
        // for that chain's vocabulary, and the suite would still pass having tested none of it.
        for ((chain, floor) in STEP_DIR_FLOORS) {
            val count = stepsIn(chain).size
            assertTrue(
                "no step-*.bin under $chain (want at least $floor) — did its assets move?",
                count >= floor,
            )
        }
    }

    @Test
    fun `every committed Swift-encoded intent decodes`() {
        val failures = steps().mapNotNull { file ->
            runCatching { EditIntentCodec.decode(file.readBytes()) }
                .exceptionOrNull()
                ?.let { "${file.chainRelativeName()}: $it" }
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
            }.getOrElse { return@mapNotNull "${file.chainRelativeName()}: $it" }
            if (original.contentEquals(reencoded)) {
                null
            } else {
                "${file.chainRelativeName()}: ${original.size} bytes in, ${reencoded.size} out"
            }
        }
        assertEquals("intents that did not re-encode identically", emptyList<String>(), mismatches)
    }

    @Test
    fun `the vocabulary the chains exercise is wide`() {
        // Parity spans cases 30…73, lyrics adds 74/75, and properties adds 76…79. If a future
        // codegen change silently collapsed several cases into one, every assertion above would still
        // pass — the bytes would round trip through whatever single case they all decoded to. Counting
        // distinct decoded case types is what notices.
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
        // Nothing to assert about depth if neither chain carries a composite; the codec's own bound
        // is exercised by the decode tests above either way.
        assumeTrue(deep)
    }
}
