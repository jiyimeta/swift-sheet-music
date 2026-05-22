import Foundation
import SheetMusicAudioCore
import SheetMusicWireFormat

/// Codec for `[GMInstrument]` — Swift is the source of truth for the
/// canonical GM Level 1 patch names; Kotlin loads this serialized blob
/// at first access via `SheetMusicAudioJNI.nativeGMInstrumentList()`.
///
/// The encoding is fully synthesized by `@WireFormat` on `GMInstrument`
/// and `@WireFormatEnum` on `GMInstrument.Family`. Wire layout:
/// ```
/// i32 instrumentCount        ← Array<T> length prefix
/// instrumentCount × {
///   u8  program              0..127
///   i32 nameByteCount        ← String length prefix
///   nameByteCount × u8       UTF-8 bytes
///   u8  familyOrdinal        0..15 (Family.allCases index)
/// }
/// ```
///
/// No version envelope — the `.so` and `.aar` are built in lockstep
/// from the same commit, so a mismatch can't occur in practice.
public enum GMInstrumentCodec {
    public static func encodeAll() -> Data {
        GMInstrument.all.encodeToData()
    }
}
