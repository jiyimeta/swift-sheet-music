import Foundation
import SheetMusicCore

/// Options controlling MIDI import behaviour. All fields have
/// defaults that produce a reasonable Score from a typical
/// notation-style SMF (DAW exports, MuseScore exports). Construct
/// with the memberwise initialiser and override only the fields you
/// care about, e.g. `MidiImportOptions(clefCandidates: [.treble])`.
public struct MidiImportOptions: Sendable {
    /// Smallest binary subdivision the quantizer will produce.
    /// Onsets finer than this snap to the grid (or to a tuplet).
    public let quantizeGrid: NoteDuration

    /// Onset fit tolerance in ticks. `nil` means `division / 16`
    /// (= 30 ticks at 480 PPQ).
    public let onsetTolerance: Int?

    /// Tuplet ratios attempted, in priority order. `[]` disables
    /// tuplet detection (everything force-snaps to the binary grid).
    public let tupletRatios: [TupletRatio]

    /// Pitch-bend → Glissando detection. Bend range is fixed at 12
    /// semitones (matching `MidiRenderer`'s pitch-bend range header).
    public let detectGlissando: Bool

    /// Maximum augmentation-dot count permitted in chord durations
    /// during the import-time rhythm decomposition. `0` = no dots
    /// (chords split into multiple tied binary durations), `1` =
    /// single dot only (the standard engraving practice and our
    /// default), `2` = up to double-dot, `3` = up to triple-dot.
    /// Higher values produce more compact notation in exchange for
    /// less common rhythmic figures.
    /// Rests are always decomposed without dots regardless of this
    /// setting.
    public let maxDots: Int

    /// Clefs the importer may assign to each pitched staff's
    /// `defaultClefType`. The track's note-on pitches are scored
    /// against each candidate's middle-line MIDI pitch (summed
    /// absolute distance); the minimum-cost candidate wins, with
    /// ties broken toward earlier entries.
    ///
    /// Drum tracks always get `.percussion` regardless of this list.
    /// Empty list or tracks with no note-ons fall back to the first
    /// entry (or `.treble` if the list itself is empty).
    public let clefCandidates: [NotatedClef]

    /// Sync resolver, used by the non-async parse path.
    public let resolveSwing: (@Sendable (SwingDetection) -> SwingResolution)?

    /// Async resolver, used by the async parse path. Falls back to
    /// `resolveSwing` if `nil` (and that is also `nil` → no swing
    /// rewrite).
    public let resolveSwingAsync: (@Sendable (SwingDetection) async -> SwingResolution)?

    public init(
        quantizeGrid: NoteDuration = .sixteenth,
        onsetTolerance: Int? = nil,
        tupletRatios: [TupletRatio] = [
            TupletRatio(actual: 3, normal: 2),
            TupletRatio(actual: 5, normal: 4),
            TupletRatio(actual: 7, normal: 4),
        ],
        detectGlissando: Bool = true,
        maxDots: Int = 1,
        clefCandidates: [NotatedClef] = [.treble, .bass],
        resolveSwing: (@Sendable (SwingDetection) -> SwingResolution)? = nil,
        resolveSwingAsync: (@Sendable (SwingDetection) async -> SwingResolution)? = nil,
    ) {
        self.quantizeGrid = quantizeGrid
        self.onsetTolerance = onsetTolerance
        self.tupletRatios = tupletRatios
        self.detectGlissando = detectGlissando
        self.maxDots = maxDots
        self.clefCandidates = clefCandidates
        self.resolveSwing = resolveSwing
        self.resolveSwingAsync = resolveSwingAsync
    }
}

/// Immutable tuplet ratio descriptor used in `MidiImportOptions`.
/// Tuple syntax (`(actual: Int, normal: Int)`) doesn't conform to
/// `Sendable` cleanly across Swift 6 boundaries, so we wrap it.
public struct TupletRatio: Sendable, Equatable {
    public let actual: Int
    public let normal: Int

    public init(actual: Int, normal: Int) {
        precondition(actual > 0 && normal > 0, "Tuplet ratio must be positive")
        self.actual = actual
        self.normal = normal
    }
}

/// Surfaced to the caller when statistical analysis suggests the
/// MIDI was performed with swing. The resolver decides whether to
/// straighten the timing or keep it as-is.
public struct SwingDetection: Sendable {
    public let trackIndex: Int
    public let measureRange: Range<Int>
    /// 1.0 = straight, 2.0 ≈ 2:1 swing, 1.5 ≈ loose swing.
    public let estimatedRatio: Double
    /// 0.0..1.0 from sample size and dispersion.
    public let confidence: Double
    public let sampleSize: Int

    public init(
        trackIndex: Int,
        measureRange: Range<Int>,
        estimatedRatio: Double,
        confidence: Double,
        sampleSize: Int,
    ) {
        self.trackIndex = trackIndex
        self.measureRange = measureRange
        self.estimatedRatio = estimatedRatio
        self.confidence = confidence
        self.sampleSize = sampleSize
    }
}

public enum SwingResolution: Sendable {
    /// Rewrite tick offsets so back-eighths land on beat midpoints.
    case treatAsSwing
    /// Leave timing untouched — D' will likely produce
    /// triplet-quarter+eighth pairs.
    case treatAsWritten
}
