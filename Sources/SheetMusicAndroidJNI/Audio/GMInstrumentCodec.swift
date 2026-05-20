import Foundation
import SheetMusicAudioCore

/// Codec for `[GMInstrument]` — Swift is the source of truth for the
/// canonical GM Level 1 patch names; Kotlin loads this serialized blob
/// at first access via `SheetMusicAudioJNI.nativeGMInstrumentList()`.
///
/// Wire layout:
/// ```
/// GMInstrumentArray
///   u16 version (= 1)
///   i32 count
///   count × {
///     u8  program       0..127
///     u8  familyIndex   0..15  (index into GMInstrument.Family.allCases)
///     u16 nameLen       UTF-8 byte length
///     nameLen × u8      UTF-8 bytes
///   }
/// ```
public enum GMInstrumentCodec {
    static let version: UInt16 = 1

    public static func encodeAll() -> Data {
        let families = GMInstrument.Family.allCases
        var w = AudioBinaryWriter()
        w.append(version)
        w.append(Int32(GMInstrument.all.count))
        for inst in GMInstrument.all {
            w.append(inst.program)
            let familyIdx = UInt8(
                clamping: families.firstIndex(of: inst.family) ?? 0,
            )
            w.append(familyIdx)
            let bytes = Array(inst.name.utf8)
            w.append(UInt16(bytes.count))
            w.append(bytes: bytes)
        }
        return w.data
    }
}
