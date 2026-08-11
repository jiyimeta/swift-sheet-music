package io.github.jiyimeta.sheetmusic.audio.model

import io.github.jiyimeta.sheetmusic.audio.serialization.InstrumentParamsCodec
import io.github.jiyimeta.wirelet.BinaryReader
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Regression guard for the wirelet-generated Kotlin `InstrumentParamsCodec`:
 * decodes a byte array produced by the SWIFT encoder
 * (`InstrumentParamsCodec.encodeArray`) for the real `instrument-change.mscx`
 * fixture (piano + a mid-score change to accordion — see
 * `InstrumentChangeMixerTests.instrumentParamsGoldenMatches` on the Swift
 * side, which pins the SAME committed bytes against a fresh Swift encode)
 * and asserts every field. Same class of failure this repo already guards
 * for `StaffParams` / `Frame` / `MetronomeBeat` via
 * [FrameMetronomeBeatStaffParamsDecoderTest] — a silently-wrong decode with
 * no thrown error.
 *
 * `instrumentParams-v1.bin` is synced from
 * `Tests/SheetMusicTests/Resources/Golden/Audio/` onto the JVM test
 * classpath by the `syncGoldenBinaries` Gradle task
 * (`SheetMusicAudioAndroid/build.gradle.kts`) — no new wiring needed here.
 */
class InstrumentParamsCodecTest {

    private fun loadGolden(name: String): ByteArray =
        javaClass.classLoader!!.getResourceAsStream("golden/$name")!!.readBytes()

    /** Decode a wirelet-encoded array: varint(outerLen) + N × (varint(len) + TLV payload). */
    private fun decodeInstrumentParamsArray(bytes: ByteArray): List<InstrumentParams> {
        val r = BinaryReader(bytes)
        val result = mutableListOf<InstrumentParams>()
        r.readLengthPrefixed { inner ->
            while (inner.remaining > 0) {
                result.add(inner.readLengthPrefixed { InstrumentParamsCodec.decodePayload(it) })
            }
        }
        return result
    }

    // Mirrors `instrument-change.mscx`'s two deduped strips: the part's
    // tick-0 Piano (ordinal 0), and the mid-score change to Accordion
    // (ordinal 1, its own live channel, GM program 21 = accordion).
    private val canonicalStrips = listOf(
        InstrumentParams(
            partIndex = 0, ordinal = 0, liveChannel = 0,
            bankLSB = 0, program = 0, isDrums = false,
            displayName = "Piano", channelVolume = 100,
        ),
        InstrumentParams(
            partIndex = 0, ordinal = 1, liveChannel = 1,
            bankLSB = 0, program = 21, isDrums = false,
            displayName = "Piano (Accordion)", channelVolume = 100,
        ),
    )

    @Test
    fun instrumentParamsGoldenDecodes() {
        val bytes = loadGolden("instrumentParams-v1.bin")
        val decoded = decodeInstrumentParamsArray(bytes)
        assertEquals(canonicalStrips, decoded)
    }

    @Test
    fun instrumentParamsCount() {
        val bytes = loadGolden("instrumentParams-v1.bin")
        val decoded = decodeInstrumentParamsArray(bytes)
        assertEquals(2, decoded.size)
    }

    @Test
    fun instrumentParamsEntry0IsPianoOnItsOwnChannel() {
        val bytes = loadGolden("instrumentParams-v1.bin")
        val e0 = decodeInstrumentParamsArray(bytes)[0]
        assertEquals(0, e0.partIndex)
        assertEquals(0, e0.ordinal)
        assertEquals(0, e0.liveChannel)
        assertEquals(0.toUByte(), e0.bankLSB)
        assertEquals(0.toUByte(), e0.program)
        assertEquals(false, e0.isDrums)
        assertEquals("Piano", e0.displayName)
        assertEquals(100.toUByte(), e0.channelVolume)
    }

    @Test
    fun instrumentParamsEntry1IsAccordionOnADifferentChannel() {
        val bytes = loadGolden("instrumentParams-v1.bin")
        val decoded = decodeInstrumentParamsArray(bytes)
        val e0 = decoded[0]
        val e1 = decoded[1]
        assertEquals(0, e1.partIndex)
        assertEquals(1, e1.ordinal)
        assertEquals(21.toUByte(), e1.program)
        assertEquals(false, e1.isDrums)
        assertEquals("Piano (Accordion)", e1.displayName)
        // The regression this codec exists to prevent: the second
        // instrument must land on its OWN live channel, not silently
        // decode onto (or collapse with) the primary's.
        assert(e1.liveChannel != e0.liveChannel) {
            "accordion liveChannel (${e1.liveChannel}) must differ from piano's (${e0.liveChannel})"
        }
    }
}
