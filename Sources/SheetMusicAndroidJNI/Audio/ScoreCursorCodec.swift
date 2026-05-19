import Foundation
import SheetMusicCore

/// Codec for `ScoreCursor` — a variable-length payload, plus a top-level
/// versioned blob.
///
/// Wire layout for `ScoreCursorPayload` (no version byte; always nested):
/// ```
///   u8 kind   0=item, 1=beat
///   case 0: ScoreItemIDPayload (variable)
///   case 1: i32 measureIndex
///           i32 tickInMeasure
///           → total 9 bytes
/// ```
///
/// Top-level `ScoreCursor` blob:
/// ```
///   u16 version (= 1)
///   ScoreCursorPayload
/// ```
public enum ScoreCursorCodec {
    /// Error thrown when the kind discriminator byte is not recognised.
    public enum DecodeError: Error {
        case unknownKind(UInt8)
    }

    static let version: UInt16 = 1

    private static let kindItem: UInt8 = 0
    private static let kindBeat: UInt8 = 1

    // MARK: - Payload

    public static func encodePayload(
        _ value: ScoreCursor,
        into w: inout AudioBinaryWriter,
    ) {
        switch value {
        case let .item(itemID):
            w.append(kindItem)
            ScoreItemIDCodec.encodePayload(itemID, into: &w)
        case let .beat(measureIndex, tickInMeasure):
            w.append(kindBeat)
            w.append(Int32(measureIndex))
            w.append(Int32(tickInMeasure))
        }
    }

    public static func decodePayload(
        _ r: inout AudioBinaryReader,
    ) throws -> ScoreCursor {
        let kind = try r.readUInt8()
        switch kind {
        case kindItem:
            let itemID = try ScoreItemIDCodec.decodePayload(&r)
            return .item(itemID)
        case kindBeat:
            let measureIndex = try Int(r.readInt32())
            let tickInMeasure = try Int(r.readInt32())
            return .beat(measureIndex: measureIndex, tickInMeasure: tickInMeasure)
        default:
            throw DecodeError.unknownKind(kind)
        }
    }

    // MARK: - Top-level blob

    public static func encode(_ value: ScoreCursor) -> Data {
        var w = AudioBinaryWriter()
        w.append(version)
        encodePayload(value, into: &w)
        return w.data
    }

    public static func decode(_ data: Data) throws -> ScoreCursor {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        return try decodePayload(&r)
    }
}
