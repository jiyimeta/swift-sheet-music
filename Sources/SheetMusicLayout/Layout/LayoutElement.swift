// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Distance between adjacent lyric verse rows, in spatiums.
/// `LayoutEngine+Placement` uses this when emitting each indexed verse.
let lyricVerseStrideInSpatiums: CGFloat = 1.7

/// Stem direction for notes / beams.
public enum StemDirection: Sendable, Equatable { case up, down }

/// Anchor describing where a `.tremoloBars` element draws its bars.
/// Geometry is pre-computed by the placement / beam passes so the
/// renderer just strokes parallel bars around `center`.
public enum TremoloAnchor: Sendable, Equatable {
    /// Bars cross a single stem. `center` is the bar block center
    /// (mid of the topmost and bottommost bar). For BEAMED chords the
    /// layout biases this toward the beam so bars sit just under the
    /// beam, matching MuseScore engraving; for UNBEAMED chords it
    /// sits at the midpoint of the (possibly extended) stem.
    case single(center: CGPoint)
    /// Bars span between two stems (two-chord tremolo). Coordinates
    /// describe the *midpoint* of each chord's stem.
    case between(leftStemMid: CGPoint, rightStemMid: CGPoint)
}

/// A single placed element in a measure's local coordinate space.
///
/// `origin` is measured from the measure's top-left corner where
/// y increases downward (screen convention). Staff step 0 (middle
/// line) corresponds to a y equal to `staffHeight / 2` within the measure.
///
/// That holds for EVERY staff, whatever its line count, because
/// `StaffMetrics.staffHeight` is the five-line REFERENCE height rather
/// than the staff's drawn one: `step` is anchored to the reference
/// staff's top line and never consults `lines()` (MuseScore's
/// `Note::updateRelLine` — see `StaffLineGeometry.topStep`). On a
/// one-line staff, step 0 is therefore 2 sp BELOW the only drawn line,
/// and "middle line" names the reference staff's middle, not any line
/// that gets painted. Anything that needs the staff's real extent —
/// where its lines stop, how far a barline spans, how tall the cursor
/// is — must go through `StaffLineGeometry`, not through `staffHeight`.
public enum LayoutElement: Sendable, Equatable {
    case clef(rawType: String, origin: CGPoint, anchor: ClefAnchor?)
    /// `clef` is the clef in force where the signature is drawn. It
    /// selects the accidental step table — MuseScore reads the same
    /// thing off the preceding clef segment in `TLayout::layoutKeySig`
    /// — so a bass staff's sharps land on F3 / C3 / … instead of the
    /// treble positions. See `KeySignatureSteps`.
    ///
    /// `naturals` carries the staff steps of the cancellation naturals
    /// drawn AHEAD of the signature itself, already resolved against
    /// `clef` (unlike `sharps` / `flats`, which are counts the renderer
    /// resolves). It is non-empty only for an explicit change that lands
    /// on C while a non-zero key was in force — see
    /// `KeySignatureSteps.cancellationNaturals`. In that case `sharps`
    /// and `flats` are both 0 and the naturals are the only glyphs.
    case keySignature(
        sharps: Int, flats: Int, clef: NotatedClef,
        naturals: [Int] = [], origin: CGPoint,
    )
    case timeSignature(numerator: Int, denominator: Int, origin: CGPoint)
    /// `origin.y` is the vertical center of the barline's stroke — for
    /// a staff with more than one line that is the staff's own center,
    /// midway between its top and bottom lines. `halfHeight` is the
    /// distance from there to each end of the stroke: normally half the
    /// staff's drawn height, but 2 sp on a one-line staff, whose height
    /// is zero.
    ///
    /// Both come from `StaffLineGeometry.barLineSpanY(sp:)`, so the
    /// engine owns the rule (including the one-line special case) and
    /// every renderer just strokes `origin.y ± halfHeight`.
    /// C++: `dom/barline.cpp:253-266`,
    /// `BARLINE_SPAN_1LINESTAFF_FROM` / `_TO` (`dom/barline.h:37-38`).
    case barLine(subtype: String?, origin: CGPoint, halfHeight: CGFloat)
    /// One ledger-line stroke, fully resolved by `LedgerLinePass`.
    /// Endpoints are in the same coordinate space as the chord the
    /// stroke belongs to, and `thickness` already carries that chord's
    /// `mag` scaling. Inserted immediately BEFORE its chord so it
    /// renders behind the chord's ink, matching MuseScore's
    /// `LedgerLine` z-order.
    ///
    /// C++: `mu::engraving::LedgerLine`.
    case ledgerLine(from: CGPoint, to: CGPoint, thickness: CGFloat)
    case note(
        step: Int,
        duration: NoteDuration,
        accidental: Accidental?,
        stem: StemDirection,
        origin: CGPoint,
        tieForward: Int?,
        tieBack: Int?,
        hasGlissando: Bool,
    )
    case chord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        hasArpeggio: Bool,
        arpeggioRawType: String?,
        isBeamed: Bool,
        voiceIndex: Int,
        // Extra stem length past `metrics.defaultStemLength` requested
        // by attached decorations (currently: tremolo bars on flagged
        // notes). The stem renderer adds this to the natural stem
        // length; tremolo placement uses the same value so the bars
        // stay centered on the extended stem.
        stemExtension: CGFloat,
        // True when the source `Chord.stemVisible == false` (i.e. MSCX
        // `<Stem><visible>0`). The stem (and its flag) is skipped at
        // toggle-off and grayed at 50% at toggle-on. Notehead visibility
        // is independent and carried by `LayoutChordNote.isInvisible`.
        // Beam suppression on hidden-stem chords is a separate concern.
        stemIsInvisible: Bool,
        // Visual scale factor for small / cue noteheads. 1.0 = normal
        // size; 0.7 = MuseScore's `Sid::smallNoteMag` default (any note
        // in the chord has `isSmall == true`). Mirrors the `mag` field
        // on `.graceChord` and is applied identically: renderers derive
        // `StaffMetrics(staffSize: metrics.staffHeight * mag)` and size
        // the notehead glyph (and ledger lines) from the scaled metrics.
        mag: CGFloat,
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
        voiceIndex: Int,
    )
    case rest(
        duration: NoteDuration,
        origin: CGPoint,
        voiceIndex: Int,
        restID: RestID,
        // Set when the rest is hung above the top staff line or
        // below the bottom one (e.g. the voice-2 whole rest that
        // the placement nudges out of voice 1's way). The renderer
        // switches to MuseScore's `restWholeLegerLine` /
        // `restHalfLegerLine` glyphs in that case so the rest comes
        // with its own short ledger stroke.
        hasLegerLine: Bool,
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
        level: Int,
        // Author-supplied beam color (`<Beam><color>`), derived at
        // emission from the beamed group's notehead color. `nil` =
        // default ink (black).
        color: ScoreColor? = nil,
    )
    case textMark(kind: TextMarkKind, text: String, origin: CGPoint)
    /// Free-form staff / system text or an instrument-change
    /// instruction, imported from MuseScore. Distinct from `.textMark`
    /// because it carries author-supplied color and the placement comes
    /// pre-shifted by the user offset declared in the source file.
    ///
    /// `style` picks the `TextStyleDefaults` row every renderer resolves
    /// against. It replaced an `isSystemText: Bool`, which could not
    /// express the third (`.instrumentChange`) style.
    case staffText(
        text: String,
        origin: CGPoint,
        color: ScoreColor?,
        style: TextStyleType,
    )
    /// Pre-typeset chord symbol with a baked-in run list (text +
    /// SMuFL accidental glyphs) and total width. The placement
    /// and run structure are computed at layout time so renderers
    /// just walk the runs.
    case harmony(LayoutHarmony)
    case fermata(subtype: String, origin: CGPoint)
    /// A breath mark or caesura between two chords. `kind` selects the
    /// SMuFL glyph (`BreathGlyph.codepoint(forKind:)`); `origin` is the
    /// glyph anchor (`.center`) in measure-local coordinates. Placement
    /// uses `BreathGlyphMetrics` so the visible glyph edge — not the
    /// typographic bbox center — aligns with the staff-line clearance.
    /// Mirrors the visibility wiring used for `.fermata`: when
    /// `Breath.visible == false`, the element is routed into the
    /// `invisibleElements` overlay (only laid out when
    /// `ScoreViewOptions.showsInvisibleElements` is on).
    case breath(kind: Breath.Kind, origin: CGPoint)
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
        isAbove: Bool,
    )
    case marker(kind: Marker.Kind, text: String, origin: CGPoint)
    /// Rehearsal letter / number drawn above the top staff at the
    /// start of its containing measure. `frame` controls whether
    /// the text is boxed, circled, or unframed.
    case rehearsalMark(
        text: String,
        origin: CGPoint,
        frame: RehearsalMark.FrameKind,
        color: ScoreColor?,
    )
    case jump(text: String, origin: CGPoint)
    case measureRepeat(count: Int, origin: CGPoint)
    /// Multi-measure rest H-bar with a count printed above. Replaces
    /// the `count` consecutive rest measures starting at this layout
    /// measure's `measureIndex`. Origin is the SMuFL anchor at the
    /// horizontal center of the measure, vertically centered on the
    /// middle staff line.
    case multiMeasureRest(
        count: Int,
        origin: CGPoint,
    )
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
        text: String,
    )
    case tieArc(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        above: Bool,
    )
    /// Horizontal melisma line drawn at the lyric baseline, from just
    /// past the syllable's text to the end of the last note the
    /// syllable covers. Emitted when a `Lyric.ticks` exceeds its
    /// anchor chord's duration. Rendered as a thin underscore-style
    /// rule matching MuseScore's convention.
    case lyricsMelisma(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
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
        toOrigin: CGPoint,
    )
    case glissandoLine(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        wavy: Bool,
        text: String?,
    )
    /// A guitar bend, in one of the two shapes MuseScore's
    /// `GuitarBendLayout::layoutStandardStaff`
    /// (`rendering/score/guitarbendlayout.cpp:82`) dispatches between:
    ///
    /// * `slight == false` — an **angular** bend (`bend`, `preBend`,
    ///   `graceNoteBend`): a two-segment polyline
    ///   `fromOrigin → vertex → toOrigin`, where `vertex` is the peak
    ///   `GuitarBendGeometry.vertex(from:to:sp:up:)` computed.
    /// * `slight == true` — a **slight** bend: a short fixed cubic hook
    ///   off one notehead, where `vertex` is the cubic's single control
    ///   point rather than a corner, and `toOrigin` is
    ///   `fromOrigin + GuitarBendGeometry.slightBendEnd(sp:)`.
    ///
    /// All three points are in the same (measure- or system-local)
    /// frame, so the translate pass shifts them together.
    case guitarBend(
        fromOrigin: CGPoint,
        vertex: CGPoint,
        toOrigin: CGPoint,
        slight: Bool,
    )
    /// A legacy MuseScore 3 bend (`<Bend>` pitch curve): pre-computed
    /// draw pieces in system-local coords. See `LegacyBendGeometry`.
    /// C++: `TLayout::layoutBend` / `TDraw::draw(const Bend*)`.
    ///
    /// Unlike `.guitarBend` this carries no anchors of its own — the
    /// curve has as many legs as the bend has points, so the geometry is
    /// resolved once at layout time and the pieces travel together.
    case legacyBend(shape: LegacyBendShape)
    case arpeggioWiggle(
        top: CGPoint,
        bottom: CGPoint,
        subtype: String?,
    )
    /// Jazz/brass inflection line hanging off a chord — fall, doit,
    /// plop, or scoop (plus their "slide" and "rough" palette
    /// variants). `origin` is the attachment point next to the
    /// notehead in measure-local coords; the `shape` payload is
    /// expressed relative to it. See `ChordLineGeometry`.
    case chordLine(
        shape: ChordLineShape,
        origin: CGPoint,
        thickness: CGFloat,
    )
    /// Beamed-stem tremolo bars. Bar count comes from
    /// `Tremolo.Subtype.rawValue` (1, 2, 3, or 4). Slant is fixed at +12°
    /// for v1 (a flat slant matches the MuseScore default sufficiently
    /// for visual review). Drawn as slanted rectangles using
    /// `metrics.beamThickness` and `metrics.beamSpacing`.
    case tremoloBars(anchor: TremoloAnchor, barCount: Int)
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
        tupletID: TupletID?,
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
        /// Lyric syllable. Carries the author-supplied color
        /// (`<Lyrics><color>`) from `Lyric.elementProperties.color`
        /// and the lyric-array index used as its verse. `anchor`
        /// identifies the chord that owns the syllable so render-only
        /// consumers can address it without mutating the score model.
        /// `nil` color = default ink. Dynamics / tempo inherit their
        /// style color and don't carry a per-element override here.
        case lyrics(
            color: ScoreColor? = nil,
            verse: Int = 0,
            anchor: VoiceElementID? = nil,
        )
    }
}

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
    /// True when this notehead's source `Note.visible == false` and the
    /// chord is being laid out with `showsInvisibleElements`. Renderers
    /// gray just this notehead. The slot is preserved regardless.
    public let isInvisible: Bool
    /// Author-supplied notehead color (`<Note><color>`), carried from
    /// `Note.elementProperties.color`. `nil` = default ink (black).
    /// Renderers also use it as the color for this note's stem, flag,
    /// and augmentation dots (MuseScore writes `<Stem>/<Hook>/<NoteDot>`
    /// colors separately, but in practice they match the notehead; a
    /// faithful per-sub-element color is a future refinement).
    public let color: ScoreColor?
    /// Parenthesis / square-bracket enclosure drawn around the accidental.
    /// `.none` (default) means no enclosure. Carried from
    /// `Note.accidentalBracket` and consumed by all three render paths
    /// (CALayer, SwiftUI Canvas, Android bridge) via `AccidentalGlyph.enclosure`.
    public let accidentalBracket: AccidentalBracket
    /// Round parentheses drawn around this notehead. `.none` (default) =
    /// none. Carried from `Note.parentheses` and consumed by all three
    /// render paths via `NoteheadParenthesisGlyph.glyphs`.
    public let parentheses: NoteParentheses

    public init(
        noteID: NoteID,
        step: Int,
        accidental: Accidental?,
        origin: CGPoint,
        tieForward: Int?,
        tieBack: Int?,
        hasGlissando: Bool,
        headType: String? = nil,
        mirror: Bool = false,
        isInvisible: Bool = false,
        color: ScoreColor? = nil,
        accidentalBracket: AccidentalBracket = .none,
        parentheses: NoteParentheses = .none,
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
        self.isInvisible = isInvisible
        self.color = color
        self.accidentalBracket = accidentalBracket
        self.parentheses = parentheses
    }

    /// Horizontal offset from `origin.x` to the visual center of the
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
