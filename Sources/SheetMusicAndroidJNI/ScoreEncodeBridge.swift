import Foundation
import SheetMusicBridgeCore
import SheetMusicCore

// MARK: - Score encoding (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeEncodeScore(...)` call site. Serializes the score behind `scoreHandle`
/// into `.mscx` or `.mscz` bytes.
///
/// This is the counterpart `nativeLoadScore` never had. Without it an Android host could open a
/// score, lay it out, play it, and edit it through `nativeApplyEditIntent` — and then had nowhere
/// to put the result: the edited score lived only in this image's handle table and died with the
/// process. `SheetMusicMSCX` has cross-compiled to Android and written both containers all along;
/// only this entry point was missing.
///
/// - Parameters:
///   - format: `0` = `.mscx`, `1` = `.mscz`, matching `ScoreEncodeBridge.Format`'s raw values.
///   - targetVersion: `0` for the encoder's own default, else the MuseScore major version — `3`
///     for the MS3-compatibility writer, `4` for MS4. `2` is detection-only on `MSCXVersion` and
///     normalizes to `3`; any other value is treated as `0`, because a host asking for MuseScore 5
///     wants the newest this library writes rather than an error it cannot act on.
///   - emitPreservedMarkup: `0` drops the source XML the model does not represent; anything else
///     keeps it. Non-zero is the default direction for the same reason `showsLyrics` uses it — a
///     host that has not been updated gets the behaviour every release before this one had.
///
/// Returns an empty `Data` when the handle is unknown, `format` names no container, or encoding
/// throws — the same "empty means no answer" contract every other entry point in this bridge uses.
public func nativeEncodeScore(
    scoreHandle: Int64,
    format: Int32,
    targetVersion: Int32,
    emitPreservedMarkup: Int32,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard format >= 0, format <= Int32(UInt8.max),
          let container = ScoreEncodeBridge.Format(rawValue: UInt8(format))
    else { return Data() }
    let version: MSCXVersion = switch targetVersion {
    case 2: .v2
    case 3: .v3
    default: .v4
    }
    let encoded = try? ScoreEncodeBridge.encode(
        score,
        format: container,
        targetVersion: version,
        emitPreservedMarkup: emitPreservedMarkup != 0,
    )
    return encoded ?? Data()
}
