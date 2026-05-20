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

// ---------------------------------------------------------------------------
// StaffAddressCodec
// ---------------------------------------------------------------------------

internal object StaffAddressCodec {
    fun encodePayload(addr: StaffAddress, w: BinaryWriter) {
        w.writeI32(addr.partIndex)
        w.writeI32(addr.staffIndexInPart)
    }
}

// ---------------------------------------------------------------------------
// VoiceElementIDCodec
// ---------------------------------------------------------------------------

internal object VoiceElementIDCodec {
    fun encodePayload(id: VoiceElementID, w: BinaryWriter) {
        StaffAddressCodec.encodePayload(id.staff, w)
        w.writeI32(id.measureIndex)
        w.writeI32(id.voiceIndex)
        w.writeI32(id.elementIndex)
    }
}

// ---------------------------------------------------------------------------
// NoteIDCodec
// ---------------------------------------------------------------------------

internal object NoteIDCodec {
    fun encode(id: NoteID): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1)
        encodePayload(id, w)
        return w.toByteArray()
    }

    fun encodePayload(id: NoteID, w: BinaryWriter) {
        StaffAddressCodec.encodePayload(id.staff, w)
        w.writeI32(id.measureIndex)
        w.writeI32(id.voiceIndex)
        w.writeI32(id.elementIndex)
        w.writeI32(id.noteIndexInChord)
    }
}

// ---------------------------------------------------------------------------
// RestIDCodec
// ---------------------------------------------------------------------------

internal object RestIDCodec {
    fun encodePayload(id: RestID, w: BinaryWriter) {
        StaffAddressCodec.encodePayload(id.staff, w)
        w.writeI32(id.measureIndex)
        w.writeI32(id.voiceIndex)
        w.writeI32(id.elementIndex)
    }
}

// ---------------------------------------------------------------------------
// TupletIDCodec
// ---------------------------------------------------------------------------

internal object TupletIDCodec {
    fun encodePayload(id: TupletID, w: BinaryWriter) {
        StaffAddressCodec.encodePayload(id.staff, w)
        w.writeI32(id.measureIndex)
        w.writeI32(id.voiceIndex)
        w.writeI32(id.startElementIndex)
    }
}

// ---------------------------------------------------------------------------
// ClefAnchorCodec
// ---------------------------------------------------------------------------

internal object ClefAnchorCodec {
    fun encodePayload(anchor: ClefAnchor, w: BinaryWriter) {
        when (anchor) {
            is ClefAnchor.Explicit -> {
                w.writeU8(0)
                VoiceElementIDCodec.encodePayload(anchor.voiceElementID, w)
            }
            is ClefAnchor.StaffDefault -> {
                w.writeU8(1)
                StaffAddressCodec.encodePayload(anchor.staff, w)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ScoreItemIDCodec
// ---------------------------------------------------------------------------

internal object ScoreItemIDCodec {
    fun encode(id: ScoreItemID): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1)
        encodePayload(id, w)
        return w.toByteArray()
    }

    fun encodePayload(id: ScoreItemID, w: BinaryWriter) {
        when (id) {
            is ScoreItemID.Note -> {
                w.writeU8(0)
                NoteIDCodec.encodePayload(id.id, w)
            }
            is ScoreItemID.Rest -> {
                w.writeU8(1)
                RestIDCodec.encodePayload(id.id, w)
            }
            is ScoreItemID.Tuplet -> {
                w.writeU8(2)
                TupletIDCodec.encodePayload(id.id, w)
            }
            is ScoreItemID.Clef -> {
                w.writeU8(3)
                ClefAnchorCodec.encodePayload(id.anchor, w)
            }
        }
    }

    fun encodeArray(ids: List<ScoreItemID>): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1)
        w.writeI32(ids.size)
        for (id in ids) encodePayload(id, w)
        return w.toByteArray()
    }
}

// ---------------------------------------------------------------------------
// ScoreCursorCodec
// ---------------------------------------------------------------------------

public object ScoreCursorCodec {
    fun encode(cursor: ScoreCursor): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1)
        encodePayload(cursor, w)
        return w.toByteArray()
    }

    public fun encodePayload(cursor: ScoreCursor, w: BinaryWriter) {
        when (cursor) {
            is ScoreCursor.Item -> {
                w.writeU8(0)
                ScoreItemIDCodec.encodePayload(cursor.item, w)
            }
            is ScoreCursor.Beat -> {
                w.writeU8(1)
                w.writeI32(cursor.measureIndex)
                w.writeI32(cursor.tickInMeasure)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MetronomeBeatCodec
// ---------------------------------------------------------------------------

internal object MetronomeBeatCodec {
    fun encodeArray(beats: List<MetronomeBeat>): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1)
        w.writeI32(beats.size)
        for (b in beats) {
            w.writeI64(b.tick)
            w.writeI32(if (b.isDownbeat) 0 else 1)
            w.writeI32(0) // reserved
        }
        return w.toByteArray()
    }
}

// ---------------------------------------------------------------------------
// StaffParamsCodec
// ---------------------------------------------------------------------------

internal object StaffParamsCodec {
    fun encodeArray(params: List<StaffParams>): ByteArray {
        val w = BinaryWriter()
        w.writeU16(1)
        w.writeI32(params.size)
        for (p in params) {
            w.writeI32(p.staffIndex)
            w.writeU8(p.bankLSB)
            w.writeU8(p.program)
            w.writeU8(if (p.isDrums) 1 else 0)
            w.writeU8(0) // reserved
            w.writeI64(p.partAddressHash)
        }
        return w.toByteArray()
    }
}
