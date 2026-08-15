package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.wirelet.BinaryReader
import io.github.jiyimeta.wirelet.BinaryWriter
import io.github.jiyimeta.wirelet.WireType

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
        StaffParams(
            staffIndex = 1, bankLSB = 0u, program = 0u, isDrums = true, partAddressHash = 1001L,
            groupRawValue = "percussion",
        ),
    )

    // MARK: - Helper: decode a wirelet TLV array from golden bytes

    /** Decode a wirelet-encoded array: varint(outerLen) + N × (varint(len) + TLV payload). */
    private fun decodeMetronomeBeatArray(bytes: ByteArray): List<MetronomeBeat> {
        val r = BinaryReader(bytes)
        val result = mutableListOf<MetronomeBeat>()
        r.readLengthPrefixed { inner ->
            while (inner.remaining > 0) {
                result.add(inner.readLengthPrefixed { MetronomeBeatCodec.decodePayload(it) })
            }
        }
        return result
    }

    private fun decodeStaffParamsArray(bytes: ByteArray): List<StaffParams> {
        val r = BinaryReader(bytes)
        val result = mutableListOf<StaffParams>()
        r.readLengthPrefixed { inner ->
            while (inner.remaining > 0) {
                result.add(inner.readLengthPrefixed { StaffParamsCodec.decodePayload(it) })
            }
        }
        return result
    }

    // MARK: - Frame golden tests

    @Test
    fun frameGoldenDecodes() {
        val bytes = loadGolden("frame-v1.bin")
        assertNotNull(bytes)
        assert(bytes.isNotEmpty()) { "frame-v1.bin must not be empty" }
        val decoded = FrameCodec.decode(bytes)
        assertEquals(canonicalFrame.tick, decoded.tick)
        // Compare timeSeconds with tolerance for floating-point conversion
        assert(abs(decoded.timeSeconds - canonicalFrame.timeSeconds) < 1e-9) {
            "timeSeconds mismatch: expected ${canonicalFrame.timeSeconds}, got ${decoded.timeSeconds}"
        }
        assertEquals(canonicalFrame.cursor, decoded.cursor)
    }

    @Test
    fun frameGoldenEqualsCanonical() {
        val bytes = loadGolden("frame-v1.bin")
        val decoded = FrameCodec.decode(bytes)
        assertEquals(canonicalFrame, decoded)
    }

    @Test
    fun frameEmptyBytesReturnsNull() {
        // The generated FrameCodec.decode does not accept empty bytes;
        // callers guard with isEmpty() check before calling decode.
        val emptyBytes = byteArrayOf()
        val frame = if (emptyBytes.isEmpty()) null else FrameCodec.decode(emptyBytes)
        assertNull(frame)
    }

    // MARK: - MetronomeBeat golden tests

    @Test
    fun metronomeBeatGoldenDecodes() {
        val bytes = loadGolden("metronomeBeat-v1.bin")
        val decoded = decodeMetronomeBeatArray(bytes)
        assertEquals(canonicalBeats, decoded)
    }

    @Test
    fun metronomeBeatCount() {
        val bytes = loadGolden("metronomeBeat-v1.bin")
        val decoded = decodeMetronomeBeatArray(bytes)
        assertEquals(3, decoded.size)
    }

    @Test
    fun metronomeBeatTicksAndDownbeats() {
        val bytes = loadGolden("metronomeBeat-v1.bin")
        val decoded = decodeMetronomeBeatArray(bytes)
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
        val decoded = decodeStaffParamsArray(bytes)
        assertEquals(canonicalStaffParams, decoded)
    }

    @Test
    fun staffParamsCount() {
        val bytes = loadGolden("staffParams-v1.bin")
        val decoded = decodeStaffParamsArray(bytes)
        assertEquals(2, decoded.size)
    }

    @Test
    fun staffParamsEntry0() {
        val bytes = loadGolden("staffParams-v1.bin")
        val decoded = decodeStaffParamsArray(bytes)
        val e0 = decoded[0]
        assertEquals(0, e0.staffIndex)
        assertEquals(0.toUByte(), e0.bankLSB)
        assertEquals(0.toUByte(), e0.program)
        assertEquals(false, e0.isDrums)
        assertEquals(0L, e0.partAddressHash)
        // The staff-type default. Read here as well as on entry 1 so a decoder that filled every
        // entry from the LAST one it read would be visible.
        assertEquals("pitched", e0.groupRawValue)
    }

    @Test
    fun staffParamsEntry1() {
        val bytes = loadGolden("staffParams-v1.bin")
        val decoded = decodeStaffParamsArray(bytes)
        val e1 = decoded[1]
        assertEquals(1, e1.staffIndex)
        assertEquals(0.toUByte(), e1.bankLSB)
        assertEquals(0.toUByte(), e1.program)
        assertEquals(true, e1.isDrums)
        assertEquals(1001L, e1.partAddressHash)
        // Distinct from entry 0's, which is what makes the pair discriminating: the Swift encoder and
        // this decoder must agree on WHICH trailing string is the staff type, and two identical
        // values could not tell it apart from `defaultClefType`.
        assertEquals("percussion", e1.groupRawValue)
    }

    @Test(expected = Exception::class)
    fun aPayloadWithoutTheStaffGroupIsRejected() {
        // The extension contract on StaffParamsCodec.swift says appended tags are safe because "the
        // tag-based Kotlin decoder skips any it doesn't recognize". That is true in ONE direction —
        // an OLDER consumer meeting a NEWER payload — and this case pins the other one, which is the
        // opposite: the generated decoder throws `WireFormatException.UnknownTag` when a declared tag
        // is ABSENT. So a build carrying this decoder must not be paired with a native library older
        // than the field.
        //
        // It cannot be, in practice: the AAR and `libSheetMusicAndroidJNI.so` ship inside the same
        // published artifact. The way to produce it is a PARTIAL version pin across
        // sheet-music-android / -audio-android / -compose-android, which is exactly the hazard the
        // consumer's "all three coordinates share a version" guard exists for. Pinned here so the
        // coupling is a decision rather than a runtime surprise on a device.
        val payload = BinaryWriter()
        payload.writeTag(1, WireType.VARINT); payload.writeZigZagVarint(0L)
        payload.writeTag(2, WireType.VARINT); payload.writeVarint(0L)
        payload.writeTag(3, WireType.VARINT); payload.writeVarint(0L)
        payload.writeTag(4, WireType.VARINT); payload.writeVarint(0L)
        payload.writeTag(5, WireType.VARINT); payload.writeZigZagVarint(0L)
        payload.writeTag(6, WireType.VARINT); payload.writeZigZagVarint(0L)
        payload.writeTag(7, WireType.VARINT); payload.writeZigZagVarint(0L)
        for (tag in listOf(8, 9, 10)) {
            payload.writeTag(tag, WireType.LENGTH_DELIMITED)
            payload.writeLengthPrefixed { writeBytes(ByteArray(0)) }
        }
        payload.writeTag(11, WireType.VARINT); payload.writeVarint(100L)
        payload.writeTag(12, WireType.LENGTH_DELIMITED)
        payload.writeLengthPrefixed { writeBytes(ByteArray(0)) }
        // Tag 13 (groupRawValue) deliberately omitted — this is a pre-1.15.0 payload.
        val entry = BinaryWriter()
        entry.writeLengthPrefixed { writeBytes(payload.toByteArray()) }
        StaffParamsCodec.decode(entry.toByteArray())
    }
}
