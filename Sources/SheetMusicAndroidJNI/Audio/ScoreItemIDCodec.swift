import Foundation
import SheetMusicCore

/// Codec for `ScoreItemID` — a variable-length payload, plus top-level
/// versioned blob and array blob.
///
/// Wire layout for `ScoreItemIDPayload` (no version byte; always nested):
/// ```
///   u8 kind   0=note, 1=rest, 2=tuplet, 3=clef
///   case 0: NoteIDPayload       (24 bytes) → total 25 bytes
///   case 1: RestIDPayload       (20 bytes) → total 21 bytes
///   case 2: TupletIDPayload     (20 bytes) → total 21 bytes
///   case 3: ClefAnchorPayload   (variable) → total 1+21 or 1+9 bytes
/// ```
///
/// Top-level `ScoreItemID` blob:
/// ```
///   u16 version (= 1)
///   ScoreItemIDPayload
/// ```
///
/// `ScoreItemIDArray` blob:
/// ```
///   u16 version (= 1)
///   i32 count
///   count × ScoreItemIDPayload
/// ```
public enum ScoreItemIDCodec {
    /// Error thrown when the kind discriminator byte is not recognised.
    public enum DecodeError: Error {
        case unknownKind(UInt8)
    }

    static let version: UInt16 = 1

    private static let kindNote: UInt8 = 0
    private static let kindRest: UInt8 = 1
    private static let kindTuplet: UInt8 = 2
    private static let kindClef: UInt8 = 3

    // MARK: - Payload

    public static func encodePayload(
        _ value: ScoreItemID,
        into w: inout AudioBinaryWriter,
    ) {
        switch value {
        case let .note(id):
            w.append(kindNote)
            PathIDCodecs.encodeNoteIDPayload(id, into: &w)
        case let .rest(id):
            w.append(kindRest)
            PathIDCodecs.encodeRestIDPayload(id, into: &w)
        case let .tuplet(id):
            w.append(kindTuplet)
            PathIDCodecs.encodeTupletIDPayload(id, into: &w)
        case let .clef(anchor):
            w.append(kindClef)
            ClefAnchorCodec.encodePayload(anchor, into: &w)
        }
    }

    public static func decodePayload(
        _ r: inout AudioBinaryReader,
    ) throws -> ScoreItemID {
        let kind = try r.readUInt8()
        switch kind {
        case kindNote:
            return try .note(PathIDCodecs.decodeNoteIDPayload(&r))
        case kindRest:
            return try .rest(PathIDCodecs.decodeRestIDPayload(&r))
        case kindTuplet:
            return try .tuplet(PathIDCodecs.decodeTupletIDPayload(&r))
        case kindClef:
            return try .clef(ClefAnchorCodec.decodePayload(&r))
        default:
            throw DecodeError.unknownKind(kind)
        }
    }

    // MARK: - Top-level blob

    public static func encode(_ value: ScoreItemID) -> Data {
        var w = AudioBinaryWriter()
        w.append(version)
        encodePayload(value, into: &w)
        return w.data
    }

    public static func decode(_ data: Data) throws -> ScoreItemID {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        return try decodePayload(&r)
    }

    // MARK: - Array blob

    public static func encodeArray(_ values: [ScoreItemID]) -> Data {
        var w = AudioBinaryWriter()
        w.append(version)
        w.append(Int32(values.count))
        for item in values {
            encodePayload(item, into: &w)
        }
        return w.data
    }

    public static func decodeArray(_ data: Data) throws -> [ScoreItemID] {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        let count = try Int(r.readInt32())
        var result: [ScoreItemID] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            try result.append(decodePayload(&r))
        }
        return result
    }
}
