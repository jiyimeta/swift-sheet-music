import CoreGraphics
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
@available(macOS 15.0, iOS 16.0, *)
public struct ScoreHitTester: Sendable {
    public let document: LayoutDocument

    public init(document: LayoutDocument) {
        self.document = document
    }

    /// Full hit-test that reports stems, flags, and beams in addition
    /// to noteheads and rests. Priority (first match wins):
    /// notehead → rest → beam → flag → stem — so a click on the
    /// beam bar returns `.beam` even if the stem rectangle also
    /// contains the point, and a click on the flag curve returns
    /// `.flag` rather than the stem it sits on top of.
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
                    y: system.origin.y + measure.origin.y)
                if let target = hitTestMeasure(
                    measure: measure, base: base,
                    point: point, sp: sp)
                {
                    return target
                }
            }
        }
        return nil
    }

    /// Convenience that only reports the "primary" selectable items.
    /// Equivalent to `hitTest(at:)` filtered to `.note` and `.rest`.
    public func itemID(at point: CGPoint) -> ScoreItemID? {
        switch hitTest(at: point) {
        case .note(let id): return .note(id)
        case .rest(let id): return .rest(id)
        default: return nil
        }
    }

    // MARK: - Per-measure dispatch

    private func hitTestMeasure(
        measure: LayoutMeasure,
        base: CGPoint,
        point: CGPoint,
        sp: CGFloat
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
        return nil
    }

    // MARK: - Notehead / Rest

    private func hitNote(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat
    ) -> ScoreHitTarget? {
        let radius = sp * 1.2
        let radiusSquared = radius * radius
        for el in measure.elements {
            guard case .chord(let notes, _, _, _, _, _, _, _) = el
            else { continue }
            for n in notes {
                let ax = base.x + n.origin.x
                let ay = base.y + n.origin.y
                let dx = point.x - ax
                let dy = point.y - ay
                if dx * dx + dy * dy <= radiusSquared {
                    return .note(n.noteID)
                }
            }
        }
        return nil
    }

    private func hitRest(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat
    ) -> ScoreHitTarget? {
        let halfWidth = sp * 1.8
        let halfHeight = sp * 2.5
        for el in measure.elements {
            guard case let .rest(_, origin, _, rid, _) = el
            else { continue }
            let ax = base.x + origin.x
            let ay = base.y + origin.y
            if abs(point.x - ax) <= halfWidth,
               abs(point.y - ay) <= halfHeight {
                return .rest(rid)
            }
        }
        return nil
    }

    // MARK: - Beam

    private func hitBeam(
        measure: LayoutMeasure,
        base: CGPoint, point: CGPoint, sp: CGFloat
    ) -> ScoreHitTarget? {
        let threshold = sp * 0.7
        for el in measure.elements {
            guard case let .beam(from, to, direction, level) = el
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
                x: base.x + from.x, y: base.y + from.y + levelDy)
            let b = CGPoint(
                x: base.x + to.x, y: base.y + to.y + levelDy)
            if distanceFromSegment(point: point, a: a, b: b) <= threshold {
                let notes = beamedChordNotes(
                    measure: measure,
                    fromX: from.x, toX: to.x,
                    fromY: from.y, toY: to.y,
                    sp: sp)
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
        sp: CGFloat
    ) -> [NoteID] {
        let loX = min(fromX, toX)
        let hiX = max(fromX, toX)
        let xTolerance = sp
        let yTolerance = sp * 0.5
        let span = toX - fromX

        var result: [NoteID] = []
        for el in measure.elements {
            guard case let .chord(
                notes, _, _, stemOrigin, _, _, isBeamed, _) = el,
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
        base: CGPoint, point: CGPoint, sp: CGFloat
    ) -> ScoreHitTarget? {
        for el in measure.elements {
            guard case let .chord(
                notes, dur, stem, _, _, _, isBeamed, _) = el,
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
                    height: flagHeight)
            } else {
                let stemX = base.x + noteX - stemXOffset
                let tipY = base.y + maxNoteY + sp * 3.5
                rect = CGRect(
                    x: stemX - flagWidth + sp * 0.1,
                    y: tipY - flagHeight,
                    width: flagWidth,
                    height: flagHeight)
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
        base: CGPoint, point: CGPoint, sp: CGFloat
    ) -> ScoreHitTarget? {
        let halfWidth = sp * 0.5
        let stemXOffset = sp * 0.59
        for el in measure.elements {
            guard case let .chord(
                notes, _, stem, stemOrigin, _, _, isBeamed, _) = el,
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
                height: max(0, stemMaxY - stemMinY))
            if rect.contains(point) {
                return .stem(notes: notes.map(\.noteID))
            }
        }
        return nil
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
        point: CGPoint, a: CGPoint, b: CGPoint
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
