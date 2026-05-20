import Foundation
import SheetMusicCore

/// Codecs for path-based identity types: `VoiceElementID`, `NoteID`,
/// `RestID`, and `TupletID`.
///
/// Wire layouts (no inner version bytes; always nested):
/// ```
/// VoiceElementIDPayload  20 bytes
///   StaffAddress (8)
///   i32 measureIndex
///   i32 voiceIndex
///   i32 elementIndex
///
/// NoteIDPayload          24 bytes
///   StaffAddress (8)
///   i32 measureIndex
///   i32 voiceIndex
///   i32 elementIndex
///   i32 noteIndexInChord
///
/// RestIDPayload          20 bytes
///   StaffAddress (8)
///   i32 measureIndex
///   i32 voiceIndex
///   i32 elementIndex
///
/// TupletIDPayload        20 bytes
///   StaffAddress (8)
///   i32 measureIndex
///   i32 voiceIndex
///   i32 startElementIndex
/// ```
///
/// Top-level `NoteID` blob (26 bytes):
/// ```
///   u16 version (= 1)
///   NoteIDPayload (24)
/// ```
public enum PathIDCodecs {
    static let version: UInt16 = 1

    // MARK: - VoiceElementID

    public static func encodeVoiceElementIDPayload(
        _ value: VoiceElementID,
        into w: inout AudioBinaryWriter,
    ) {
        StaffAddressCodec.encodePayload(value.staff, into: &w)
        w.append(Int32(value.measureIndex))
        w.append(Int32(value.voiceIndex))
        w.append(Int32(value.elementIndex))
    }

    public static func decodeVoiceElementIDPayload(
        _ r: inout AudioBinaryReader,
    ) throws -> VoiceElementID {
        let staff = try StaffAddressCodec.decodePayload(&r)
        let measureIndex = try Int(r.readInt32())
        let voiceIndex = try Int(r.readInt32())
        let elementIndex = try Int(r.readInt32())
        return VoiceElementID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
        )
    }

    // MARK: - NoteID payload

    public static func encodeNoteIDPayload(
        _ value: NoteID,
        into w: inout AudioBinaryWriter,
    ) {
        StaffAddressCodec.encodePayload(value.staff, into: &w)
        w.append(Int32(value.measureIndex))
        w.append(Int32(value.voiceIndex))
        w.append(Int32(value.elementIndex))
        w.append(Int32(value.noteIndexInChord))
    }

    public static func decodeNoteIDPayload(
        _ r: inout AudioBinaryReader,
    ) throws -> NoteID {
        let staff = try StaffAddressCodec.decodePayload(&r)
        let measureIndex = try Int(r.readInt32())
        let voiceIndex = try Int(r.readInt32())
        let elementIndex = try Int(r.readInt32())
        let noteIndexInChord = try Int(r.readInt32())
        return NoteID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
            noteIndexInChord: noteIndexInChord,
        )
    }

    // MARK: - NoteID top-level blob

    /// Encode `NoteID` as a versioned top-level blob (26 bytes).
    public static func encode(_ value: NoteID) -> Data {
        var w = AudioBinaryWriter()
        w.append(version)
        encodeNoteIDPayload(value, into: &w)
        return w.data
    }

    /// Decode a versioned `NoteID` top-level blob.
    public static func decode(_ data: Data) throws -> NoteID {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        return try decodeNoteIDPayload(&r)
    }

    // MARK: - RestID

    public static func encodeRestIDPayload(
        _ value: RestID,
        into w: inout AudioBinaryWriter,
    ) {
        StaffAddressCodec.encodePayload(value.staff, into: &w)
        w.append(Int32(value.measureIndex))
        w.append(Int32(value.voiceIndex))
        w.append(Int32(value.elementIndex))
    }

    public static func decodeRestIDPayload(
        _ r: inout AudioBinaryReader,
    ) throws -> RestID {
        let staff = try StaffAddressCodec.decodePayload(&r)
        let measureIndex = try Int(r.readInt32())
        let voiceIndex = try Int(r.readInt32())
        let elementIndex = try Int(r.readInt32())
        return RestID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
        )
    }

    // MARK: - TupletID

    public static func encodeTupletIDPayload(
        _ value: TupletID,
        into w: inout AudioBinaryWriter,
    ) {
        StaffAddressCodec.encodePayload(value.staff, into: &w)
        w.append(Int32(value.measureIndex))
        w.append(Int32(value.voiceIndex))
        w.append(Int32(value.startElementIndex))
    }

    public static func decodeTupletIDPayload(
        _ r: inout AudioBinaryReader,
    ) throws -> TupletID {
        let staff = try StaffAddressCodec.decodePayload(&r)
        let measureIndex = try Int(r.readInt32())
        let voiceIndex = try Int(r.readInt32())
        let startElementIndex = try Int(r.readInt32())
        return TupletID(
            staff: staff,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            startElementIndex: startElementIndex,
        )
    }
}
