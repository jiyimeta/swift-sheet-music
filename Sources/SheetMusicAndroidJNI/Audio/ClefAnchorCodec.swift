import Foundation
import SheetMusicCore

/// Codec for `ClefAnchor` — a variable-length payload.
///
/// Wire layout (no version byte; always nested):
/// ```
/// ClefAnchorPayload
///   u8 kind                       0=explicit, 1=staffDefault
///   if kind == 0: VoiceElementIDPayload  (20 bytes) → total 21 bytes
///   if kind == 1: StaffAddress           (8 bytes)  → total  9 bytes
/// ```
public enum ClefAnchorCodec {
    /// Error thrown when the kind discriminator byte is not recognised.
    public enum DecodeError: Error {
        case unknownKind(UInt8)
    }

    private static let kindExplicit: UInt8 = 0
    private static let kindStaffDefault: UInt8 = 1

    public static func encodePayload(
        _ value: ClefAnchor,
        into w: inout AudioBinaryWriter,
    ) {
        switch value {
        case let .explicit(id):
            w.append(kindExplicit)
            PathIDCodecs.encodeVoiceElementIDPayload(id, into: &w)
        case let .staffDefault(staff):
            w.append(kindStaffDefault)
            StaffAddressCodec.encodePayload(staff, into: &w)
        }
    }

    public static func decodePayload(
        _ r: inout AudioBinaryReader,
    ) throws -> ClefAnchor {
        let kind = try r.readUInt8()
        switch kind {
        case kindExplicit:
            let id = try PathIDCodecs.decodeVoiceElementIDPayload(&r)
            return .explicit(id)
        case kindStaffDefault:
            let staff = try StaffAddressCodec.decodePayload(&r)
            return .staffDefault(staff)
        default:
            throw DecodeError.unknownKind(kind)
        }
    }
}
