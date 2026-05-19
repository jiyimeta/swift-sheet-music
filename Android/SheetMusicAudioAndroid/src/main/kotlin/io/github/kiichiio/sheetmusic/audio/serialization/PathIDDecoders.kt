package io.github.kiichiio.sheetmusic.audio.serialization

import io.github.kiichiio.sheetmusic.audio.model.NoteID
import io.github.kiichiio.sheetmusic.audio.model.RestID
import io.github.kiichiio.sheetmusic.audio.model.StaffAddress
import io.github.kiichiio.sheetmusic.audio.model.TupletID
import io.github.kiichiio.sheetmusic.audio.model.VoiceElementID

/**
 * Payload decoder for [StaffAddress].
 * Reads partIndex (i32) + staffIndexInPart (i32) — 8 bytes total.
 * No version byte; callers own version handling for top-level blobs.
 */
object StaffAddressDecoder {
    fun decodePayload(r: BinaryReader): StaffAddress = StaffAddress(
        partIndex = r.readI32(),
        staffIndexInPart = r.readI32(),
    )

    /** Top-level decode: reads a 2-byte version header then delegates to [decodePayload]. */
    fun decode(data: ByteArray): StaffAddress {
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        return decodePayload(r)
    }
}

/**
 * Payload decoder for [VoiceElementID].
 * Reads StaffAddress payload + measureIndex + voiceIndex + elementIndex — 20 bytes total.
 */
object VoiceElementIDDecoder {
    fun decodePayload(r: BinaryReader): VoiceElementID = VoiceElementID(
        staff = StaffAddressDecoder.decodePayload(r),
        measureIndex = r.readI32(),
        voiceIndex = r.readI32(),
        elementIndex = r.readI32(),
    )
}

/**
 * Top-level decoder for [NoteID].
 * Wire format: version(u16) + StaffAddress(8) + measureIndex(4) + voiceIndex(4)
 *              + elementIndex(4) + noteIndexInChord(4) = 26 bytes.
 */
object NoteIDDecoder {
    fun decodePayload(r: BinaryReader): NoteID = NoteID(
        staff = StaffAddressDecoder.decodePayload(r),
        measureIndex = r.readI32(),
        voiceIndex = r.readI32(),
        elementIndex = r.readI32(),
        noteIndexInChord = r.readI32(),
    )

    fun decode(data: ByteArray): NoteID {
        val r = BinaryReader(data)
        val version = r.readU16()
        if (version != 1) throw BinaryReader.VersionMismatchException(1, version)
        return decodePayload(r)
    }
}

/**
 * Payload decoder for [RestID].
 * Reads StaffAddress payload + measureIndex + voiceIndex + elementIndex — 20 bytes total.
 */
object RestIDDecoder {
    fun decodePayload(r: BinaryReader): RestID = RestID(
        staff = StaffAddressDecoder.decodePayload(r),
        measureIndex = r.readI32(),
        voiceIndex = r.readI32(),
        elementIndex = r.readI32(),
    )
}

/**
 * Payload decoder for [TupletID].
 * Reads StaffAddress payload + measureIndex + voiceIndex + startElementIndex — 20 bytes total.
 */
object TupletIDDecoder {
    fun decodePayload(r: BinaryReader): TupletID = TupletID(
        staff = StaffAddressDecoder.decodePayload(r),
        measureIndex = r.readI32(),
        voiceIndex = r.readI32(),
        startElementIndex = r.readI32(),
    )
}
