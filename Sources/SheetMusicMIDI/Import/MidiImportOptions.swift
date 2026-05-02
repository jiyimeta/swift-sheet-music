import Foundation
import SheetMusicCore

/// Options controlling MIDI import behaviour. All fields have
/// defaults that produce a reasonable Score from a typical
/// notation-style SMF (DAW exports, MuseScore exports).
public struct MidiImportOptions: Sendable {
    /// Smallest binary subdivision the quantizer will produce.
    /// Onsets finer than this snap to the grid (or to a tuplet).
    public var quantizeGrid: NoteDuration = .sixteenth

    /// Onset fit tolerance in ticks. `nil` means `division / 16`
    /// (= 30 ticks at 480 PPQ).
    public var onsetTolerance: Int?

    /// Tuplet ratios attempted, in priority order. `[]` disables
    /// tuplet detection (everything force-snaps to the binary grid).
    public var tupletRatios: [TupletRatio] = [
        TupletRatio(actual: 3, normal: 2),
        TupletRatio(actual: 5, normal: 4),
        TupletRatio(actual: 7, normal: 4),
    ]

    /// Pitch-bend → Glissando detection. Bend range is fixed at 12
    /// semitones (matching `MidiRenderer`'s pitch-bend range header).
    public var detectGlissando: Bool = true

    /// Sync resolver, used by the non-async parse path.
    public var resolveSwing: (@Sendable (SwingDetection) -> SwingResolution)?

    /// Async resolver, used by the async parse path. Falls back to
    /// `resolveSwing` if `nil` (and that is also `nil` → no swing
    /// rewrite).
    public var resolveSwingAsync: (@Sendable (SwingDetection) async -> SwingResolution)?

    public init() {}
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
        sampleSize: Int
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
