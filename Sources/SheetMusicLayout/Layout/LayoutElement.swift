import CoreGraphics
import SheetMusicCore

/// Stem direction for notes / beams.
@available(macOS 15.0, iOS 16.0, *)
public enum StemDirection: Sendable, Equatable { case up, down }

/// A single placed element in a measure's local coordinate space.
///
/// `origin` is measured from the measure's top-left corner where
/// y increases downward (screen convention). Staff step 0 (middle
/// line) corresponds to a y equal to `staffHeight / 2` within the measure.
@available(macOS 15.0, iOS 16.0, *)
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
        isBeamed: Bool,
        voiceIndex: Int
    )
    /// A grace note (or grace chord) drawn at reduced size next to
    /// its parent main chord. Carries a `relativeX` offset from the
    /// main notehead (negative for before-graces, positive for
    /// after-graces) so the renderer can position it without
    /// holding a reference to the parent.
    case graceChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        relativeX: CGFloat,
        hasSlash: Bool,
        mag: CGFloat,
        voiceIndex: Int
    )
    case rest(
        duration: NoteDuration,
        origin: CGPoint,
        voiceIndex: Int,
        restID: RestID,
        /// Set when the rest is hung above the top staff line or
        /// below the bottom one (e.g. the voice-2 whole rest that
        /// the placement nudges out of voice 1's way). The renderer
        /// switches to MuseScore's `restWholeLegerLine` /
        /// `restHalfLegerLine` glyphs in that case so the rest comes
        /// with its own short ledger stroke.
        hasLegerLine: Bool
    )
    /// A single beam bar at `level` (1 = primary, 2 = first secondary,
    /// …). A note group with mixed durations emits one `beam` per bar
    /// per run of consecutive members that need that level, so that a
    /// dotted-8th + 16th pair has one primary beam + one partial
    /// secondary stub on the 16th (not two full beams across both).
    case beam(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        direction: StemDirection,
        level: Int
    )
    case textMark(kind: TextMarkKind, text: String, origin: CGPoint)
    /// Free-form staff or system text imported from MuseScore.
    /// Distinct from `.textMark` because it carries author-supplied
    /// colour and the placement comes pre-shifted by the user offset
    /// declared in the source file.
    case staffText(
        text: String,
        origin: CGPoint,
        color: ScoreColor?,
        isSystemText: Bool
    )
    /// Pre-typeset chord symbol with a baked-in run list (text +
    /// SMuFL accidental glyphs) and total width. The placement
    /// and run structure are computed at layout time so renderers
    /// just walk the runs.
    case harmony(LayoutHarmony)
    case fermata(subtype: String, origin: CGPoint)
    /// Per-chord articulation glyph (staccato dot / staccatissimo wedge /
    /// tenuto bar). Emitted from `placeMeasureElements` for each
    /// `ChordArticulation` whose `kind` is in scope; round-trip-only
    /// `.unknown(...)` entries are filtered out before reaching layout.
    /// `origin` is the SMuFL glyph anchor in measure-local coords;
    /// `isAbove` selects the above-vs-below glyph variant and is also
    /// used by the YBounds pass.
    case articulation(
        kind: ArticulationKind,
        origin: CGPoint,
        isAbove: Bool
    )
    case marker(kind: Marker.Kind, text: String, origin: CGPoint)
    /// Rehearsal letter / number drawn above the top staff at the
    /// start of its containing measure. `frame` controls whether
    /// the text is boxed, circled, or unframed.
    case rehearsalMark(
        text: String,
        origin: CGPoint,
        frame: RehearsalMark.FrameKind,
        color: ScoreColor?
    )
    case jump(text: String, origin: CGPoint)
    case measureRepeat(count: Int, origin: CGPoint)
    /// 1-based measure number drawn above a staff. Emitted for every
    /// staff at the first measure of every system in vertical / page
    /// modes so that readers can locate themselves after a system
    /// break. Mirrors MuseScore's per-system measure-number layout.
    case measureNumber(text: String, origin: CGPoint)
    /// Staff / instrument name drawn above a staff with leading
    /// alignment at `origin.x`. Used by the horizontal continuous-
    /// view sticky pane (mirrors MuseScore's `continuouspanel.cpp`
    /// staff-name rendering at `(clefLeftMargin + widthClef, -2 sp)`)
    /// where the part label sits above the staff rather than to its
    /// left, with the text free to overflow the pane's white box if
    /// the name is long.
    case staffName(text: String, origin: CGPoint)
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
    /// Horizontal melisma line drawn at the lyric baseline, from just
    /// past the syllable's text to the end of the last note the
    /// syllable covers. Emitted when a `Lyric.ticks` exceeds its
    /// anchor chord's duration. Rendered as a thin underscore-style
    /// rule matching MuseScore's convention.
    case lyricsMelisma(
        fromOrigin: CGPoint,
        toOrigin: CGPoint
    )
    /// One short horizontal stroke between two adjacent syllables of
    /// the same word ("Pa-ra-di-so" → three hyphens). Multiple
    /// segments may be emitted for a wide gap; the layout decides
    /// how many and where, mirroring MuseScore's
    /// `LyricsLayout::layoutDashes`. Drawn at the lyric text's
    /// midline (between baseline and cap-height) — distinct from the
    /// melisma rule, which sits on the underline.
    case lyricHyphen(
        fromOrigin: CGPoint,
        toOrigin: CGPoint
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
    /// Tuplet marking — bracket (when `hasBracket` is true) with a
    /// number in the middle, or number alone (when beamed). `fromOrigin`
    /// and `toOrigin` define the horizontal span of the first and last
    /// tuplet members. `isAbove` controls which side of the staff it
    /// sits on. `tupletID` identifies the source `Tuplet` entry for
    /// hit-testing, when one is available.
    case tupletLabel(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        text: String,
        hasBracket: Bool,
        isAbove: Bool,
        tupletID: TupletID?
    )

    /// Layout-local subset of `ChordArticulation.Kind` containing only
    /// the renderable cases. The emitter filters `.unknown(...)` out
    /// before producing a `LayoutElement`, so the renderer's switch
    /// stays exhaustive without a `default` clause.
    public enum ArticulationKind: Sendable, Equatable {
        case staccato
        case staccatissimo
        case tenuto
        case accent
        case marcato
        case accentStaccato
        case marcatoStaccato
    }

    public enum TextMarkKind: Sendable, Equatable {
        case dynamic
        case tempo
        case lyrics
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

@available(macOS 15.0, iOS 16.0, *)
public struct LayoutChordNote: Sendable, Equatable {
    public let noteID: NoteID
    public let step: Int
    public let accidental: Accidental?
    public let origin: CGPoint
    public let tieForward: Int?
    public let tieBack: Int?
    public let hasGlissando: Bool
    public let headType: String?
    /// True when this notehead must be drawn on the OPPOSITE side of
    /// the stem from the chord's natural side — i.e. the right side
    /// for a stem-up chord, the left side for a stem-down chord.
    /// Set during placement when the note participates in a "second"
    /// cluster (adjacent staff lines / spaces). Mirrors MuseScore's
    /// `ChordLayout::layoutChords2`.
    public let mirror: Bool

    public init(
        noteID: NoteID,
        step: Int,
        accidental: Accidental?,
        origin: CGPoint,
        tieForward: Int?,
        tieBack: Int?,
        hasGlissando: Bool,
        headType: String? = nil,
        mirror: Bool = false
    ) {
        self.noteID = noteID
        self.step = step
        self.accidental = accidental
        self.origin = origin
        self.tieForward = tieForward
        self.tieBack = tieBack
        self.hasGlissando = hasGlissando
        self.headType = headType
        self.mirror = mirror
    }

    /// Horizontal offset from `origin.x` to the visual centre of the
    /// notehead. Zero unless `mirror` is set, in which case the head
    /// shifts by one notehead-width (Bravura's `noteheadBlack`
    /// width = 1.18 sp) to the side opposite the chord's natural
    /// side. Used by renderers and the hit-tester so the visible
    /// glyph and click target track the mirrored position while
    /// `origin` keeps anchoring the stem and ledger lines.
    public func mirrorDx(stem: StemDirection, sp: CGFloat) -> CGFloat {
        guard mirror else { return 0 }
        return (stem == .up ? 1 : -1) * sp * 1.18
    }
}

@available(macOS 15.0, iOS 16.0, *)
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
