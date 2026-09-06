import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMSCX

/// The write half of `ScoreBridge`.
///
/// Kept separate from `ScoreBridge` because the two halves are not symmetric and pretending they
/// are would mislead: reading dispatches across five formats through `ScoreLoader`, while writing
/// has exactly two targets. MusicXML is import-only in this package, and a `writeScore` that
/// silently refused `.musicXML` while accepting the same `SniffedFormat` value the reader hands
/// back is the kind of near-symmetry that produces a bug report rather than a caught error.
public enum ScoreEncodeBridge {
    /// A container this package can write.
    ///
    /// Raw values are the wire contract with the Kotlin host — `nativeEncodeScore` takes this as an
    /// `Int32` — so they are assigned explicitly and never reordered.
    public enum Format: UInt8, Sendable, CaseIterable {
        /// Plain `.mscx` XML.
        case mscx = 0
        /// A `.mscz` ZIP container holding `META-INF/container.xml` and `score.mscx`.
        case mscz = 1
    }

    /// Serialize `score` into `format`.
    ///
    /// - Parameters:
    ///   - targetVersion: which MuseScore wire-form variant to write. `.v2` is detection-only and
    ///     `MSCXEncoderOptions` normalizes it to `.v3`; this function does not second-guess that.
    ///   - emitPreservedMarkup: whether to write back the source XML the model does not represent.
    ///     Preserved markup is source fidelity rather than a semantic guarantee — an edit can leave
    ///     a preserved `<Excerpt>` describing the *original* part layout — so a host preparing an
    ///     edited score for distribution passes `false`. See
    ///     `docs/development/mscx-preserved-markup.md`.
    public static func encode(
        _ score: Score,
        format: Format,
        targetVersion: MSCXVersion = .v4,
        emitPreservedMarkup: Bool = true,
    ) throws -> Data {
        var options = MSCXEncoderOptions(targetVersion: targetVersion)
        options.emitPreservedMarkup = emitPreservedMarkup
        let mscx = try MSCXEncoder.encode(score, options: options)
        switch format {
        case .mscx:
            return mscx
        case .mscz:
            return try MSCZWriter.write(mscxData: mscx)
        }
    }
}
