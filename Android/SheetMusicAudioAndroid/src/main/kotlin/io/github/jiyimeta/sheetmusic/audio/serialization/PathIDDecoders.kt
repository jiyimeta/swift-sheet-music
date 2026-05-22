package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.sheetmusic.audio.model.NoteID
import io.github.jiyimeta.sheetmusic.audio.model.RestID
import io.github.jiyimeta.sheetmusic.audio.model.StaffAddress
import io.github.jiyimeta.sheetmusic.audio.model.TupletID
import io.github.jiyimeta.sheetmusic.audio.model.VoiceElementID

/**
 * Payload decoder for [StaffAddress].
 * Reads partIndex (i32) + staffIndexInPart (i32) — 8 bytes total.
 *
 * Wire format produced by Swift's `@WireFormat` on `StaffAddressWire`.
 * No version envelope (top-level codecs no longer emit one).
 */
object StaffAddressDecoder {
    fun decodePayload(r: BinaryReader): StaffAddress = StaffAddress(
        partIndex = r.readI32(),
        staffIndexInPart = r.readI32(),
    )

    fun decode(data: ByteArray): StaffAddress = decodePayload(BinaryReader(data))
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
 * Wire: StaffAddress(8) + i32 × 4 (measure / voice / element / noteIndexInChord) = 24 bytes.
 */
object NoteIDDecoder {
    fun decodePayload(r: BinaryReader): NoteID = NoteID(
        staff = StaffAddressDecoder.decodePayload(r),
        measureIndex = r.readI32(),
        voiceIndex = r.readI32(),
        elementIndex = r.readI32(),
        noteIndexInChord = r.readI32(),
    )

    fun decode(data: ByteArray): NoteID = decodePayload(BinaryReader(data))
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
