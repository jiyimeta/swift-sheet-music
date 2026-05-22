package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.Frame
import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.math.abs

class FrameMetronomeBeatStaffParamsDecoderTest {

    private fun loadGolden(name: String): ByteArray =
        javaClass.classLoader!!.getResourceAsStream("golden/$name")!!.readBytes()

    // MARK: - Canonical values (matching GoldenBinaryTests.swift)

    private val canonicalNoteID = NoteID(
        staff = StaffAddress(partIndex = 1, staffIndexInPart = 0),
        measureIndex = 4,
        voiceIndex = 0,
        elementIndex = 2,
        noteIndexInChord = 1,
    )

    private val canonicalCursor = ScoreCursor.Item(ScoreItemID.Note(canonicalNoteID))

    // Frame(tick=480, timeSeconds=1.5, cursor=canonicalCursor)
    private val canonicalFrame = Frame(
        tick = 480L,
        timeSeconds = 1.5,
        cursor = canonicalCursor,
    )

    // [MetronomeBeat(0, true), MetronomeBeat(480, false), MetronomeBeat(960, true)]
    private val canonicalBeats = listOf(
        MetronomeBeat(tick = 0L, isDownbeat = true),
        MetronomeBeat(tick = 480L, isDownbeat = false),
        MetronomeBeat(tick = 960L, isDownbeat = true),
    )

    // [StaffParams(0,0,0,false,0), StaffParams(1,0,0,true,1001)]
    private val canonicalStaffParams = listOf(
        StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false, partAddressHash = 0L),
        StaffParams(staffIndex = 1, bankLSB = 0, program = 0, isDrums = true, partAddressHash = 1001L),
    )

    // MARK: - Frame golden tests

    @Test
    fun frameGoldenDecodes() {
        val bytes = loadGolden("frame-v1.bin")
        val decoded = FrameDecoder.decode(bytes)
        assertNotNull(decoded)
        assertEquals(canonicalFrame.tick, decoded!!.tick)
        // Compare timeSeconds with tolerance for floating-point conversion
        assert(abs(decoded.timeSeconds - canonicalFrame.timeSeconds) < 1e-9) {
            "timeSeconds mismatch: expected ${canonicalFrame.timeSeconds}, got ${decoded.timeSeconds}"
        }
        assertEquals(canonicalFrame.cursor, decoded.cursor)
    }

    @Test
    fun frameGoldenEqualsCanonical() {
        val bytes = loadGolden("frame-v1.bin")
        val decoded = FrameDecoder.decode(bytes)!!
        assertEquals(canonicalFrame, decoded)
    }

    @Test
    fun frameEmptyBytesReturnsNull() {
        val decoded = FrameDecoder.decode(byteArrayOf())
        assertNull(decoded)
    }

    // MARK: - MetronomeBeat golden tests

    @Test
    fun metronomeBeatGoldenDecodes() {
        val bytes = loadGolden("metronomeBeat-v1.bin")
        val decoded = MetronomeBeatDecoder.decodeArray(bytes)
        assertEquals(canonicalBeats, decoded)
    }

    @Test
    fun metronomeBeatCount() {
        val bytes = loadGolden("metronomeBeat-v1.bin")
        val decoded = MetronomeBeatDecoder.decodeArray(bytes)
        assertEquals(3, decoded.size)
    }

    @Test
    fun metronomeBeatTicksAndDownbeats() {
        val bytes = loadGolden("metronomeBeat-v1.bin")
        val decoded = MetronomeBeatDecoder.decodeArray(bytes)
        assertEquals(0L, decoded[0].tick)
        assertEquals(true, decoded[0].isDownbeat)
        assertEquals(480L, decoded[1].tick)
        assertEquals(false, decoded[1].isDownbeat)
        assertEquals(960L, decoded[2].tick)
        assertEquals(true, decoded[2].isDownbeat)
    }

    // MARK: - StaffParams golden tests

    @Test
    fun staffParamsGoldenDecodes() {
        val bytes = loadGolden("staffParams-v1.bin")
        val decoded = StaffParamsDecoder.decodeArray(bytes)
        assertEquals(canonicalStaffParams, decoded)
    }

    @Test
    fun staffParamsCount() {
        val bytes = loadGolden("staffParams-v1.bin")
        val decoded = StaffParamsDecoder.decodeArray(bytes)
        assertEquals(2, decoded.size)
    }

    @Test
    fun staffParamsEntry0() {
        val bytes = loadGolden("staffParams-v1.bin")
        val decoded = StaffParamsDecoder.decodeArray(bytes)
        val e0 = decoded[0]
        assertEquals(0, e0.staffIndex)
        assertEquals(0, e0.bankLSB)
        assertEquals(0, e0.program)
        assertEquals(false, e0.isDrums)
        assertEquals(0L, e0.partAddressHash)
    }

    @Test
    fun staffParamsEntry1() {
        val bytes = loadGolden("staffParams-v1.bin")
        val decoded = StaffParamsDecoder.decodeArray(bytes)
        val e1 = decoded[1]
        assertEquals(1, e1.staffIndex)
        assertEquals(0, e1.bankLSB)
        assertEquals(0, e1.program)
        assertEquals(true, e1.isDrums)
        assertEquals(1001L, e1.partAddressHash)
    }
}
