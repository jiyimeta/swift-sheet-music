import Foundation
import SheetMusicCore

/// Codec for `StaffAddress` — an 8-byte fixed-size payload.
///
/// Wire layout (no version byte; always nested inside a top-level blob):
/// ```
///   i32 partIndex         (4 bytes LE)
///   i32 staffIndexInPart  (4 bytes LE)
/// ```
public enum StaffAddressCodec {
    public static func encodePayload(
        _ value: StaffAddress,
        into w: inout AudioBinaryWriter,
    ) {
        w.append(Int32(value.partIndex))
        w.append(Int32(value.staffIndexInPart))
    }

    public static func decodePayload(
        _ r: inout AudioBinaryReader,
    ) throws -> StaffAddress {
        let partIndex = try Int(r.readInt32())
        let staffIndexInPart = try Int(r.readInt32())
        return StaffAddress(
            partIndex: partIndex,
            staffIndexInPart: staffIndexInPart,
        )
    }
}
