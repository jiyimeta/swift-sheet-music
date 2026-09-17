// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Maps a point in a `ScoreView`'s local coordinate space to the
/// engraving element underneath it, if any.
///
/// `ScoreView` renders into a frame whose top-left corresponds to the
/// origin of its `LayoutDocument` (i.e. `(0, 0)` in document coords).
/// Points received from a SwiftUI gesture (`.onTapGesture { loc in … }`)
/// on `ScoreView` are therefore valid inputs to `hitTest(at:)` and
/// `itemID(at:)`.
///
/// The tester holds a `LayoutDocument`. Compute one via
/// `LayoutEngine.layout(score:options:availableWidth:)` with the same
/// arguments you pass to `ScoreView`:
///
/// ```swift
/// GeometryReader { proxy in
///     let doc = LayoutEngine.layout(
///         score: score, options: options,
///         availableWidth: proxy.size.width)
///     let tester = ScoreHitTester(document: doc)
///     ScoreView(document: doc, score: score)
///         .onTapGesture { loc in
///             switch tester.hitTest(at: loc) {
///             case .note(let id):           // ...
///             case .beam(let notes):        // ...
///             // ...
///             case nil:                      // ...
///             }
///         }
/// }
/// ```
@available(macOS 15.0, *)
public struct ScoreHitTester: Sendable {
    public let document: LayoutDocument

    public init(document: LayoutDocument) {
        self.document = document
    }

    /// Full hit-test: every engraving element this tester knows, not just the primary selectable ones.
    ///
    /// First match wins, down a fixed priority ladder. The ladder is documented once, on `ScoreHitTarget` —
    /// duplicating the order here is how the previous copy went stale (it still read
    /// "notehead → rest → beam → flag → stem" two rungs after tuplet and clef were added).
    public func hitTest(at point: CGPoint) -> ScoreHitTarget? {
        let sp = document.metrics.sp
        for system in document.systems {
            let yPad = sp * 4
            guard point.y >= system.origin.y - yPad,
                  point.y <= system.origin.y + system.size.height + yPad
            else { continue }

            for measure in system.measures {
                // Generous x-pad so beams and stems that spill past
                // the measure's nominal width still match.
                let xPad = sp * 2
                let mMinX = system.origin.x + measure.origin.x
                let mMaxX = mMinX + measure.width
                guard point.x >= mMinX - xPad,
                      point.x <= mMaxX + xPad
                else { continue }

                let base = CGPoint(
                    x: system.origin.x + measure.origin.x,
                    y: system.origin.y + measure.origin.y,
                )
                if let target = hitTestMeasure(
                    measure: measure, base: base,
                    point: point, sp: sp,
                ) {
                    return target
                }
            }
        }
        // 9. Engraved elements, after the earlier rungs in every measure have declined.
        //    System spanners and elements outside nominal measure bounds participate here too.
        return hitElement(at: point)
    }

    /// Reports directly selectable notation identities, including clefs and engraved elements.
    /// Text and shared note geometry are excluded; hosts can use a hit's `selectableItem`
    /// when their interaction policy also selects those targets.
    public func itemID(at point: CGPoint) -> ScoreItemID? {
        guard let target = hitTest(at: point) else { return nil }
        switch target {
        case let .note(id): return .note(id)
        case let .rest(id): return .rest(id)
        case let .tuplet(id): return .tuplet(id)
        case let .clef(anchor): return .clef(anchor)
        case let .graceNote(id): return .graceNote(id)
        case .dynamic, .fermata, .breath, .tempo, .spanner, .keySignature, .timeSignature, .barLine, .articulation,
             .tie, .slur, .jump, .marker, .glissando:
            return target.elementID.map(ScoreItemID.element)
        case .stem, .flag, .beam, .lyric, .staffText, .harmony, .rehearsalMark:
            return nil
        }
    }

    // MARK: - Per-measure dispatch

    private func hitTestMeasure(
        measure: LayoutMeasure,
        base: CGPoint,
        point: CGPoint,
        sp: CGFloat,
    ) -> ScoreHitTarget? {
        // 1. Notehead (smallest, highest priority)
        if let target = hitNote(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // 2. Rest
        if let target = hitRest(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // 3. Beam bar — checked before stem so clicking the beam
        //    line itself resolves to beam rather than the stem
        //    endpoint below it.
        if let target = hitBeam(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // 4. Flag — before stem so the flag tip resolves to flag.
        if let target = hitFlag(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // 5. Stem
        if let target = hitStem(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // 6. Tuplet bracket / number — after note geometry so a click
        //    on a notehead inside the bracket still selects the
        //    note. The bracket is a thin strip at the top/bottom
        //    of the tuplet's vertical extent, plus a small label
        //    box around the number.
        if let target = hitTuplet(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // 7. Clef glyph — after shared note geometry and tuplets.
        if let target = hitClef(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // 8. Engraved text — lyrics, staff / system text, chord
        //    symbols, rehearsal marks. After note geometry, so a click
        //    plainly on a note stays a note. Today's autoplace keeps
        //    the two apart by ~0.15 sp, so this ordering is
        //    defence-in-depth rather than a rule anything exercises;
        //    `ScoreHitTarget`'s doc comment has the measurement.
        if let target = hitText(measure: measure, base: base, point: point, sp: sp) {
            return target
        }
        // Rung 9 is deferred to hitTest so an overlap with a later measure keeps its earlier-rung target.
        return nil
    }

    /// Hit-test a tuplet bracket / number. The bracket itself is a
    /// thin horizontal segment around `from.y`/`to.y`, with the
    /// number sitting at the midpoint. We accept the click if it
    /// falls within `~0.5 sp` of either the bracket span or the
    /// number's bounding box — generous enough to be clickable
    /// without snagging clicks intended for notes nearby.
    private func hitTuplet(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let bracketTolerance = sp * 0.6
        let labelHalfHeight = sp * 1.2
        let labelHalfWidth = sp * 1.0
        for el in measure.elements {
            guard case let .tupletLabel(from, to, _, _, _, tid) = el,
                  let tupletID = tid
            else { continue }
            let aFromX = base.x + from.x
            let aFromY = base.y + from.y
            let aToX = base.x + to.x
            let aToY = base.y + to.y
            // Bracket span: horizontal strip from (fromX, fromY) to
            // (toX, toY). For a sloped bracket we approximate the
            // hit zone with the line's bounding box widened by the
            // tolerance. For our level of precision a flat strip
            // around the average y is enough.
            let avgY = (aFromY + aToY) / 2
            let spanLo = min(aFromX, aToX)
            let spanHi = max(aFromX, aToX)
            if point.x >= spanLo && point.x <= spanHi
                && abs(point.y - avgY) <= bracketTolerance
            {
                return .tuplet(tupletID)
            }
            // Label (the number "3", "5", etc.) sits at the
            // midpoint of the bracket. A small box is enough.
            let labelX = (aFromX + aToX) / 2
            let labelY = avgY
            if abs(point.x - labelX) <= labelHalfWidth
                && abs(point.y - labelY) <= labelHalfHeight
            {
                return .tuplet(tupletID)
            }
        }
        return nil
    }

    // MARK: - Notehead / Rest

    /// Ordinary heads keep first-match order; a grace head overrides that only from inside its own `mag`-scaled
    /// reach and when strictly nearer than every ordinary head that also claims the point. `ScoreHitTarget`'s ladder
    /// doc has the reason. A measure without graces never enters the grace branch, so its answer is the first match
    /// exactly as before graces could be hit at all.
    private func hitNote(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let radius = sp * 1.2
        let radiusSquared = radius * radius
        var firstNote: NoteID?
        var nearestNoteDistanceSquared = CGFloat.infinity
        var nearestGrace: (id: GraceNoteID, distanceSquared: CGFloat)?
        func distanceSquared(_ note: LayoutChordNote, stem: StemDirection, sp: CGFloat) -> CGFloat {
            let dx = point.x - (base.x + note.origin.x + note.mirrorDx(stem: stem, sp: sp))
            let dy = point.y - (base.y + note.origin.y)
            return dx * dx + dy * dy
        }
        for el in measure.elements {
            switch el {
            case let .chord(notes, _, stem, _, _, _, _, _, _, _, _):
                for n in notes {
                    let d2 = distanceSquared(n, stem: stem, sp: sp)
                    guard d2 <= radiusSquared else { continue }
                    if firstNote == nil { firstNote = n.noteID }
                    nearestNoteDistanceSquared = min(nearestNoteDistanceSquared, d2)
                }
            case let .graceChord(notes, _, stem, _, _, _, mag, _):
                let graceRadiusSquared = radiusSquared * mag * mag
                for n in notes {
                    guard let id = n.graceNoteID else { continue }
                    let d2 = distanceSquared(n, stem: stem, sp: sp * mag)
                    guard d2 <= graceRadiusSquared, d2 < nearestGrace?.distanceSquared ?? .infinity else { continue }
                    nearestGrace = (id, d2)
                }
            default:
                continue
            }
        }
        if let nearestGrace, nearestGrace.distanceSquared < nearestNoteDistanceSquared {
            return .graceNote(nearestGrace.id)
        }
        return firstNote.map(ScoreHitTarget.note)
    }

    private func hitRest(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let halfWidth = sp * 1.8
        let halfHeight = sp * 2.5
        for el in measure.elements {
            guard case let .rest(_, origin, _, rid, _) = el
            else { continue }
            let ax = base.x + origin.x
            let ay = base.y + origin.y
            if abs(point.x - ax) <= halfWidth,
               abs(point.y - ay) <= halfHeight
            {
                return .rest(rid)
            }
        }
        return nil
    }

    // MARK: - Beam

    private func hitBeam(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let threshold = sp * 0.7
        for el in measure.elements {
            guard case let .beam(from, to, direction, level, _) = el
            else { continue }
            // Secondary beams (level >= 2) are drawn offset from the
            // stored `from`/`to` Y toward the noteheads. Mirror the
            // offset used in `drawBeam` so the hit test matches the
            // visible bar instead of the primary beam line.
            //   stackSign: +1 for stem-up, -1 for stem-down
            //   thickness = 0.5 sp, gap between bars = 0.3 sp
            let stackSign: CGFloat = direction == .up ? 1 : -1
            let levelDy = CGFloat(level - 1)
                * (sp * 0.5 + sp * 0.3) * stackSign
            let a = CGPoint(
                x: base.x + from.x, y: base.y + from.y + levelDy,
            )
            let b = CGPoint(
                x: base.x + to.x, y: base.y + to.y + levelDy,
            )
            if distanceFromSegment(point: point, a: a, b: b) <= threshold {
                let notes = beamedChordNotes(
                    measure: measure,
                    fromX: from.x, toX: to.x,
                    fromY: from.y, toY: to.y,
                    sp: sp,
                )
                return .beam(notes: notes)
            }
        }
        return nil
    }

    /// All noteheads of chords that belong to this particular beam.
    ///
    /// A `LayoutMeasure` aggregates elements across every staff and
    /// voice in the system, so a pure x-range filter would sweep in
    /// other voices / other staves that happen to sit at the same
    /// beat. We additionally require the chord's primary-beam anchor
    /// Y (`stemOrigin.y`, set equal to the beam Y at placement time)
    /// to land on the beam line — this narrows the match to the one
    /// voice×staff that actually owns this beam.
    ///
    /// The x tolerance is one full sp so that the first and last
    /// members of the group survive the `stemSideDx` (±0.59 sp)
    /// offset between a chord's anchor x and its stem x.
    private func beamedChordNotes(
        measure: LayoutMeasure,
        fromX: CGFloat, toX: CGFloat,
        fromY: CGFloat, toY: CGFloat,
        sp: CGFloat,
    ) -> [NoteID] {
        let loX = min(fromX, toX)
        let hiX = max(fromX, toX)
        let xTolerance = sp
        let yTolerance = sp * 0.5
        let span = toX - fromX

        var result: [NoteID] = []
        for el in measure.elements {
            guard case let .chord(
                notes, _, _, stemOrigin, _, _, isBeamed, _, _, _, _,
            ) = el,
                isBeamed,
                stemOrigin.x >= loX - xTolerance,
                stemOrigin.x <= hiX + xTolerance
            else { continue }
            let expectedY: CGFloat
            if abs(span) < 0.001 {
                expectedY = fromY
            } else {
                let t = (stemOrigin.x - fromX) / span
                expectedY = fromY + t * (toY - fromY)
            }
            guard abs(stemOrigin.y - expectedY) <= yTolerance
            else { continue }
            result.append(contentsOf: notes.map(\.noteID))
        }
        return result
    }

    // MARK: - Flag

    private func hitFlag(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        for el in measure.elements {
            guard case let .chord(
                notes, dur, stem, _, _, _, isBeamed, _, _, _, _,
            ) = el,
                !isBeamed,
                Self.hasFlag(dur),
                let noteX = notes.first?.origin.x
            else { continue }
            let ys = notes.map(\.origin.y)
            guard let minNoteY = ys.min(),
                  let maxNoteY = ys.max()
            else { continue }
            let stemXOffset = sp * 0.59
            let flagWidth = sp * 1.5
            let flagHeight = sp * 2.0
            let rect: CGRect
            if stem == .up {
                let stemX = base.x + noteX + stemXOffset
                let tipY = base.y + minNoteY - sp * 3.5
                rect = CGRect(
                    x: stemX - sp * 0.1,
                    y: tipY,
                    width: flagWidth,
                    height: flagHeight,
                )
            } else {
                let stemX = base.x + noteX - stemXOffset
                let tipY = base.y + maxNoteY + sp * 3.5
                rect = CGRect(
                    x: stemX - flagWidth + sp * 0.1,
                    y: tipY - flagHeight,
                    width: flagWidth,
                    height: flagHeight,
                )
            }
            if rect.contains(point) {
                return .flag(notes: notes.map(\.noteID))
            }
        }
        return nil
    }

    // MARK: - Stem

    private func hitStem(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        let halfWidth = sp * 0.5
        let stemXOffset = sp * 0.59
        for el in measure.elements {
            guard case let .chord(
                notes, _, stem, stemOrigin, _, _, isBeamed, _, _, _, _,
            ) = el,
                let noteX = notes.first?.origin.x
            else { continue }
            let ys = notes.map(\.origin.y)
            guard let minNoteY = ys.min(),
                  let maxNoteY = ys.max()
            else { continue }
            let stemX: CGFloat
            let stemMinY: CGFloat
            let stemMaxY: CGFloat
            if stem == .up {
                stemX = base.x + noteX + stemXOffset
                stemMinY = isBeamed
                    ? base.y + stemOrigin.y
                    : base.y + minNoteY - sp * 3.5
                stemMaxY = base.y + maxNoteY
            } else {
                stemX = base.x + noteX - stemXOffset
                stemMinY = base.y + minNoteY
                stemMaxY = isBeamed
                    ? base.y + stemOrigin.y
                    : base.y + maxNoteY + sp * 3.5
            }
            let rect = CGRect(
                x: stemX - halfWidth,
                y: stemMinY,
                width: halfWidth * 2,
                height: max(0, stemMaxY - stemMinY),
            )
            if rect.contains(point) {
                return .stem(notes: notes.map(\.noteID))
            }
        }
        return nil
    }

    // MARK: - Clef

    /// Bounding-box hit-test for a clef glyph. Mirrors the
    /// per-clef y-offset that `drawClef` applies (treble +1 sp,
    /// bass −1 sp, C-clef 0). Returns nil for clefs without an
    /// `anchor` — the sticky header's, which is chrome over the score.
    /// A continuation system's restatement HAS one: its own bar's.
    private func hitClef(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat,
    ) -> ScoreHitTarget? {
        // The glyph's own box (≈ 2 sp wide, ≈ 5 sp tall), plus the reach every engraved element gets — see
        // `ScoreHitTester.elementHitTolerance`. A clef is narrow enough that its ink alone made it a target a
        // pointer had to be placed on exactly.
        let halfWidth = sp * (1.0 + Self.elementHitTolerance)
        let halfHeight = sp * (2.5 + Self.elementHitTolerance)
        for el in measure.elements {
            guard case let .clef(rawType, origin, anchor) = el,
                  let anchor
            else { continue }
            let yOffset = Self.clefYOffset(rawType: rawType, sp: sp)
            let ax = base.x + origin.x
            let ay = base.y + origin.y + yOffset
            if abs(point.x - ax) <= halfWidth,
               abs(point.y - ay) <= halfHeight
            {
                return .clef(anchor)
            }
        }
        return nil
    }

    /// y-offset applied by the renderer for `rawType`. Kept in
    /// sync with `ScoreLayerBuilder.drawClef`'s switch.
    static func clefYOffset(
        rawType: String, sp: CGFloat,
    ) -> CGFloat {
        switch NotatedClef(rawType: rawType) {
        case .treble, .treble8va, .treble8vb, .treble15ma, .treble15mb:
            sp
        case .bass, .bass8va, .bass8vb:
            -sp
        case .soprano:
            2 * sp
        case .alto, .percussion, .percussion2:
            0
        case .tenor:
            -sp
        case .baritone:
            -2 * sp
        }
    }

    // MARK: - Utilities

    /// True when `dur` (considered after splitting off augmentation
    /// dots) would be drawn with a flag — i.e. 8th or shorter. Used
    /// to skip flag hit-testing on unflagged chord durations.
    private static func hasFlag(_ dur: NoteDuration) -> Bool {
        let (base, _) = DurationInterpretation.split(dur)
        switch base {
        case .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            return true
        default:
            return false
        }
    }

    /// Shortest distance from `point` to the line segment `a`—`b`.
    private func distanceFromSegment(
        point: CGPoint, a: CGPoint, b: CGPoint,
    ) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSquared = dx * dx + dy * dy
        guard lenSquared > 0 else {
            let px = point.x - a.x
            let py = point.y - a.y
            return (px * px + py * py).squareRoot()
        }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSquared
        t = max(0, min(1, t))
        let closestX = a.x + t * dx
        let closestY = a.y + t * dy
        let ex = point.x - closestX
        let ey = point.y - closestY
        return (ex * ex + ey * ey).squareRoot()
    }
}
