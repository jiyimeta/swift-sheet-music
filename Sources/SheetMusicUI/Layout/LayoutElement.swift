#if os(macOS)
import CoreGraphics
import SheetMusicCore

/// Stem direction for notes / beams.
@available(macOS 15.0, *)
public enum StemDirection: Sendable, Equatable { case up, down }

/// A single placed element in a measure's local coordinate space.
///
/// `origin` is measured from the measure's top-left corner where
/// y increases downward (screen convention). Staff step 0 (middle
/// line) corresponds to a y equal to `staffHeight / 2` within the measure.
@available(macOS 15.0, *)
public enum LayoutElement: Sendable, Equatable {
    case clef(rawType: String, origin: CGPoint)
    case keySignature(sharps: Int, flats: Int, origin: CGPoint)
    case timeSignature(numerator: Int, denominator: Int, origin: CGPoint)
    case barLine(subtype: String?, origin: CGPoint)
    case note(
        step: Int,
        duration: NoteDuration,
        accidental: Accidental?,
        stem: StemDirection,
        origin: CGPoint,
        tieForward: Int?,
        tieBack: Int?,
        hasGlissando: Bool
    )
    case chord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        hasArpeggio: Bool,
        arpeggioRawType: String?,
        isBeamed: Bool
    )
    case rest(duration: NoteDuration, origin: CGPoint)
    case beam(fromOrigin: CGPoint, toOrigin: CGPoint, levels: Int)
    case textMark(kind: TextMarkKind, text: String, origin: CGPoint)
    case fermata(subtype: String, origin: CGPoint)
    case marker(kind: Marker.Kind, text: String, origin: CGPoint)
    case jump(text: String, origin: CGPoint)
    case measureRepeat(count: Int, origin: CGPoint)
    case spannerSegment(
        kind: SpannerKind,
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        continuesLeft: Bool,
        continuesRight: Bool,
        text: String
    )
    case tieArc(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        above: Bool
    )
    case glissandoLine(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        wavy: Bool,
        text: String?
    )
    case arpeggioWiggle(
        top: CGPoint,
        bottom: CGPoint,
        subtype: String?
    )

    public enum TextMarkKind: Sendable, Equatable {
        case dynamic
        case tempo
    }

    public enum SpannerKind: Sendable, Equatable {
        case slur
        case volta(endings: [Int])
        case hairpinOpen
        case hairpinClose
        case pedal
        case ottava(raw: String)
        case textLine
    }
}

@available(macOS 15.0, *)
public struct LayoutChordNote: Sendable, Equatable {
    public let step: Int
    public let accidental: Accidental?
    public let origin: CGPoint
    public let tieForward: Int?
    public let tieBack: Int?
    public let hasGlissando: Bool

    public init(
        step: Int,
        accidental: Accidental?,
        origin: CGPoint,
        tieForward: Int?,
        tieBack: Int?,
        hasGlissando: Bool
    ) {
        self.step = step
        self.accidental = accidental
        self.origin = origin
        self.tieForward = tieForward
        self.tieBack = tieBack
        self.hasGlissando = hasGlissando
    }
}

@available(macOS 15.0, *)
public enum StemDirectionRule {
    /// Median heuristic: if the chord median step is at or below 0
    /// (the middle line), stems go up. Otherwise down.
    /// `steps` are staff steps for each notehead (see `PitchStaffPosition`).
    public static func direction(for steps: [Int]) -> StemDirection {
        guard !steps.isEmpty else { return .up }
        let sorted = steps.sorted()
        let median: Double
        if sorted.count.isMultiple(of: 2) {
            let a = sorted[sorted.count / 2 - 1]
            let b = sorted[sorted.count / 2]
            median = (Double(a) + Double(b)) / 2
        } else {
            median = Double(sorted[sorted.count / 2])
        }
        return median <= 0 ? .up : .down
    }
}
#endif
