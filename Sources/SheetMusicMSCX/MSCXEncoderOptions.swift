import SheetMusicCore
import SheetMusicFoundation

/// Knobs for `MSCXEncoder.encode(_:options:)`.
///
/// `targetVersion` selects which MuseScore wire-form variant the
/// encoder produces. Defaults to `.v4` so existing call sites that
/// use the zero-arg `encode(_:)` overload retain MS4 output.
///
/// `.v2` is a detection-only marker on `MSCXVersion` (the decoder
/// uses it to report MuseScore 2 provenance via `ScoreSource`); the
/// encoder has no MS2 writer, so passing `.v2` here is normalized to
/// `.v3` at construction time. That keeps the per-element encoder
/// switches a tight `.v3` / `.v4` pair and prevents `.v2` from ever
/// reaching them.
public struct MSCXEncoderOptions: Sendable {
    public var targetVersion: MSCXVersion {
        didSet {
            if targetVersion == .v2 {
                targetVersion = .v3
            }
        }
    }

    public init(targetVersion: MSCXVersion = .v4) {
        self.targetVersion = targetVersion == .v2 ? .v3 : targetVersion
    }
}
