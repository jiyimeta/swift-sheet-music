import Foundation
import SheetMusicBridgeCore
import SheetMusicCore

// MARK: - Diagnostic-carrying score load (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeLoadScoreWithDiagnostics(...)` call site: `nativeLoadScore` plus the two
/// things it throws away.
///
/// `nativeLoadScore` answers `0` for every failure. A corrupt ZIP, an unrecognized format, a
/// structurally invalid `<Measure>` and an empty file are one answer, so an Android host can only
/// say "could not open this file" where an Apple host has a `ScoreFault` whose dotted `code` is a
/// localization key.
///
/// The second thing is easier to miss and matters more often: the parsers are permissive by design
/// (ARCHITECTURE.md, "Parser policy"), so an unknown tremolo subtype or an unrepresentable ornament
/// is *dropped* and the score loads anyway. `MSCXParser.parseWithDiagnostics` is how an Apple host
/// learns that happened; without this entry point no Android host could.
///
/// Returns a `ScoreLoadResultWire` payload. A non-zero `scoreHandle` must be released with
/// `nativeReleaseScore`, exactly as `nativeLoadScore`'s return value must. Empty `Data` is returned
/// only if encoding the result itself fails, which cannot happen for these field types — the failure
/// case is a *decodable* result carrying `scoreHandle == 0` and a fault code, not an empty blob.
public func nativeLoadScoreWithDiagnostics(bytes: Data) -> Data {
    guard !bytes.isEmpty else {
        return ScoreLoadResultWire(
            failure: .malformedScore(
                ScoreFault(
                    code: "bridge.scoreFormat.empty",
                    message: "no bytes to parse",
                ),
            ),
        ).encodeToData()
    }
    do {
        let loaded = try ScoreBridge.loadScoreWithDiagnostics(bytes: bytes)
        return ScoreLoadResultWire(
            scoreHandle: scoreTable.insert(loaded.score),
            diagnostics: loaded.diagnostics,
        ).encodeToData()
    } catch let error as SheetMusicError {
        return ScoreLoadResultWire(failure: error).encodeToData()
    } catch {
        // Every parser in this package throws `SheetMusicError`, so this is unreachable today. It is
        // a `catch` rather than a `try!` because the alternative to an honest generic code here is
        // trapping the host's process over a parse failure.
        return ScoreLoadResultWire(
            failure: .malformedScore(
                ScoreFault(
                    code: "bridge.scoreLoad.unexpected",
                    message: "parser threw a non-SheetMusicError: \(error)",
                ),
            ),
        ).encodeToData()
    }
}
