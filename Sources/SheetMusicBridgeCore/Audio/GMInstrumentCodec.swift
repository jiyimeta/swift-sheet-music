import SheetMusicAudioCore
import SheetMusicFoundation
import Wirelet

/// Codec for `[GMInstrument]` — Swift is the source of truth for the
/// canonical GM Level 1 patch names; Kotlin loads this serialized blob
/// at first access via `SheetMusicAudioJNI.nativeGMInstrumentList()`.
///
/// The encoding is fully synthesized by `@WireFormat` on `GMInstrument`
/// and `@WireFormatEnum` on `GMInstrument.Family`. Wire layout (wirelet TLV):
/// ```
/// varint arrayPayloadLen              ← outer Array<T> length prefix
/// arrayPayloadLen bytes {
///   N × {
///     varint itemPayloadLen           ← per-item struct length prefix
///     itemPayloadLen bytes {
///       tag(1, .varint)     varint program    0..127 (UInt8)
///       tag(2, .lengthDelimited) varint nameLen + nameLen UTF-8 bytes
///       tag(3, .lengthDelimited) varint rawLen  + rawLen  UTF-8 bytes
///                                              ← Family.rawValue e.g. "Piano"
///     }
///   }
/// }
/// ```
///
/// `GMInstrument.Family` has `String` rawValues, so `@WireFormatEnum`
/// encodes the rawValue string (not a numeric ordinal). The Kotlin decoder
/// maps the rawValue back to a `familyIndex` by looking it up in the
/// canonical `Family.allCases` order.
///
/// No version envelope — the `.so` and `.aar` are built in lockstep
/// from the same commit, so a mismatch can't occur in practice.
public enum GMInstrumentCodec {
    public static func encodeAll() -> Data {
        GMInstrument.all.encodeToData()
    }
}
