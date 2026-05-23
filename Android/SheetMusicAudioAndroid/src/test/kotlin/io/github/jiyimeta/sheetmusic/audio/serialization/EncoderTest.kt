package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.ClefAnchor
import io.github.jiyimeta.sheetmusic.audio.model.MetronomeBeat
import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.ScoreCursor
import io.github.jiyimeta.sheetmusic.audio.model.ScoreItemID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.StaffParams
import io.github.jiyimeta.sheetmusic.audio.model.TupletID
import io.github.jiyimeta.sheetmusic.audio.model.VoiceElementID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Round-trip tests for all codecs — encode then decode should equal the original value.
 * Uses generated XxxCodec objects throughout.
 */
class EncoderTest {

    // ── canonical values ──────────────────────────────────────────────────

    private val canonicalStaffAddress = StaffAddress(partIndex = 1, staffIndexInPart = 0)

    private val canonicalNoteID = NoteID(
        staff = canonicalStaffAddress,
        measureIndex = 4,
        voiceIndex = 0,
        elementIndex = 2,
        noteIndexInChord = 1,
    )

    private val canonicalCursorItem = ScoreCursor.Item(ScoreItemID.Note(canonicalNoteID))
    private val canonicalCursorBeat = ScoreCursor.Beat(measureIndex = 3, tickInMeasure = 240)

    private val canonicalRestID = RestID(
        staff = canonicalStaffAddress,
        measureIndex = 1,
        voiceIndex = 0,
        elementIndex = 3,
    )

    private val canonicalVoiceElementID = VoiceElementID(
        staff = canonicalStaffAddress,
        measureIndex = 2,
        voiceIndex = 1,
        elementIndex = 5,
    )

    private val canonicalTupletID = TupletID(
        staff = canonicalStaffAddress,
        measureIndex = 3,
        voiceIndex = 0,
        startElementIndex = 7,
    )

    private val canonicalClefExplicit = ClefAnchor.Explicit(canonicalVoiceElementID)
    private val canonicalClefDefault = ClefAnchor.StaffDefault(canonicalStaffAddress)

    // ── NoteIDCodec ───────────────────────────────────────────────────────

    @Test fun noteIDCodec_roundTrip() {
        val encoded = NoteIDCodec.encode(canonicalNoteID)
        val decoded = NoteIDCodec.decode(encoded)
        assertEquals(canonicalNoteID, decoded)
    }

    // ── ScoreItemIDCodec ──────────────────────────────────────────────────

    @Test fun scoreItemIDCodec_note_roundTrip() {
        val id = ScoreItemID.Note(canonicalNoteID)
        val encoded = ScoreItemIDCodec.encode(id)
        val decoded = ScoreItemIDCodec.decode(encoded)
        assertEquals(id, decoded)
    }

    @Test fun scoreItemIDCodec_rest_roundTrip() {
        val id = ScoreItemID.Rest(canonicalRestID)
        val encoded = ScoreItemIDCodec.encode(id)
        val decoded = ScoreItemIDCodec.decode(encoded)
        assertEquals(id, decoded)
    }

    @Test fun scoreItemIDCodec_tuplet_roundTrip() {
        val id = ScoreItemID.Tuplet(canonicalTupletID)
        val encoded = ScoreItemIDCodec.encode(id)
        val decoded = ScoreItemIDCodec.decode(encoded)
        assertEquals(id, decoded)
    }

    @Test fun scoreItemIDCodec_clefExplicit_roundTrip() {
        val id = ScoreItemID.Clef(canonicalClefExplicit)
        val encoded = ScoreItemIDCodec.encode(id)
        val decoded = ScoreItemIDCodec.decode(encoded)
        assertEquals(id, decoded)
    }

    @Test fun scoreItemIDCodec_clefDefault_roundTrip() {
        val id = ScoreItemID.Clef(canonicalClefDefault)
        val encoded = ScoreItemIDCodec.encode(id)
        val decoded = ScoreItemIDCodec.decode(encoded)
        assertEquals(id, decoded)
    }

    @Test fun scoreItemIDCodec_encodeArray_roundTrip() {
        val ids = listOf(
            ScoreItemID.Note(canonicalNoteID),
            ScoreItemID.Rest(canonicalRestID),
        )
        // Encode array: i32 count + payload per item
        val w = BinaryWriter()
        w.writeI32(ids.size)
        for (id in ids) ScoreItemIDCodec.encodePayload(id, w)
        val encoded = w.toByteArray()
        // Decode array
        val r = BinaryReader(encoded)
        val count = r.readI32()
        val decoded = ArrayList<ScoreItemID>(count)
        for (i in 0 until count) decoded.add(ScoreItemIDCodec.decodePayload(r))
        assertEquals(ids, decoded)
    }

    @Test fun scoreItemIDCodec_emptyArray_roundTrip() {
        val w = BinaryWriter()
        w.writeI32(0)
        val encoded = w.toByteArray()
        val r = BinaryReader(encoded)
        val count = r.readI32()
        val decoded = ArrayList<ScoreItemID>(count)
        for (i in 0 until count) decoded.add(ScoreItemIDCodec.decodePayload(r))
        assertEquals(emptyList<ScoreItemID>(), decoded)
    }

    // ── ScoreCursorCodec ──────────────────────────────────────────────────

    @Test fun scoreCursorCodec_item_roundTrip() {
        val encoded = ScoreCursorCodec.encode(canonicalCursorItem)
        val decoded = ScoreCursorCodec.decode(encoded)
        assertEquals(canonicalCursorItem, decoded)
    }

    @Test fun scoreCursorCodec_beat_roundTrip() {
        val encoded = ScoreCursorCodec.encode(canonicalCursorBeat)
        val decoded = ScoreCursorCodec.decode(encoded)
        assertEquals(canonicalCursorBeat, decoded)
    }

    // ── MetronomeBeatCodec ────────────────────────────────────────────────

    @Test fun metronomeBeatCodec_roundTrip() {
        val beats = listOf(
            MetronomeBeat(tick = 0L, isDownbeat = true),
            MetronomeBeat(tick = 480L, isDownbeat = false),
            MetronomeBeat(tick = 960L, isDownbeat = true),
        )
        // Encode array: i32 count + payload per beat
        val w = BinaryWriter()
        w.writeI32(beats.size)
        for (b in beats) MetronomeBeatCodec.encodePayload(b, w)
        val encoded = w.toByteArray()
        // Decode array
        val r = BinaryReader(encoded)
        val count = r.readI32()
        val decoded = ArrayList<MetronomeBeat>(count)
        for (i in 0 until count) decoded.add(MetronomeBeatCodec.decodePayload(r))
        assertEquals(beats, decoded)
    }

    @Test fun metronomeBeatCodec_emptyArray_roundTrip() {
        val w = BinaryWriter()
        w.writeI32(0)
        val encoded = w.toByteArray()
        val r = BinaryReader(encoded)
        val count = r.readI32()
        val decoded = ArrayList<MetronomeBeat>(count)
        for (i in 0 until count) decoded.add(MetronomeBeatCodec.decodePayload(r))
        assertEquals(emptyList<MetronomeBeat>(), decoded)
    }

    // ── StaffParamsCodec ──────────────────────────────────────────────────

    @Test fun staffParamsCodec_roundTrip() {
        val params = listOf(
            StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false, partAddressHash = 0L),
            StaffParams(staffIndex = 1, bankLSB = 0, program = 0, isDrums = true, partAddressHash = 1001L),
        )
        // Encode array
        val w = BinaryWriter()
        w.writeI32(params.size)
        for (p in params) StaffParamsCodec.encodePayload(p, w)
        val encoded = w.toByteArray()
        // Decode array
        val r = BinaryReader(encoded)
        val count = r.readI32()
        val decoded = ArrayList<StaffParams>(count)
        for (i in 0 until count) decoded.add(StaffParamsCodec.decodePayload(r))
        assertEquals(params, decoded)
    }

    @Test fun staffParamsCodec_goldenBytes_matchDecoder() {
        // Verify encode output is identical to the Swift-generated golden binary.
        val params = listOf(
            StaffParams(staffIndex = 0, bankLSB = 0, program = 0, isDrums = false, partAddressHash = 0L),
            StaffParams(staffIndex = 1, bankLSB = 0, program = 0, isDrums = true, partAddressHash = 1001L),
        )
        val w = BinaryWriter()
        w.writeI32(params.size)
        for (p in params) StaffParamsCodec.encodePayload(p, w)
        val encoded = w.toByteArray()
        val golden = javaClass.classLoader!!.getResourceAsStream("golden/staffParams-v1.bin")!!
            .readBytes()
        assertArrayEquals("encode(canonical) must match Swift golden binary", golden, encoded)
    }

    @Test fun metronomeBeatCodec_goldenBytes_matchDecoder() {
        val beats = listOf(
            MetronomeBeat(tick = 0L, isDownbeat = true),
            MetronomeBeat(tick = 480L, isDownbeat = false),
            MetronomeBeat(tick = 960L, isDownbeat = true),
        )
        val w = BinaryWriter()
        w.writeI32(beats.size)
        for (b in beats) MetronomeBeatCodec.encodePayload(b, w)
        val encoded = w.toByteArray()
        val golden = javaClass.classLoader!!.getResourceAsStream("golden/metronomeBeat-v1.bin")!!
            .readBytes()
        assertArrayEquals("encode(canonical) must match Swift golden binary", golden, encoded)
    }
}
