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

    /// Whether to write source XML that the model does not represent.
    ///
    /// Preserved markup provides source fidelity, not a semantic
    /// guarantee: editing a score can leave an unmodeled subtree such
    /// as `<Excerpt>` stale. Keeping it is normally safer than deleting
    /// it, but a host preparing an edited score for distribution can
    /// set this to `false` to omit all preserved markup.
    public var emitPreservedMarkup = true

    /// Line-of-fifths shift from the concert notation to the written one for the part currently
    /// being encoded — `Instrument.writtenFifthsOffset`. `0` for a non-transposing part, which is
    /// what every element encoder outside the per-part measure loop sees; the Score encoder makes a
    /// per-part copy of the options before emitting that part's staff bodies.
    ///
    /// mscx stores the *concert* pitch/key in `<pitch>` / `<tpc>` / `<concertKey>` and the
    /// *written* one alongside it (`<tpc2>`, and `<actualKey>` / `<accidental>` on a `<KeySig>`),
    /// so the note and key-signature encoders need this to fill the written half in.
    ///
    /// `package`, not `public`: the Score encoder overwrites it once per part, so any value an
    /// external caller set would be discarded before it reached an element encoder.
    package var writtenFifthsOffset = 0

    public init(targetVersion: MSCXVersion = .v4) {
        self.targetVersion = targetVersion == .v2 ? .v3 : targetVersion
    }
}
