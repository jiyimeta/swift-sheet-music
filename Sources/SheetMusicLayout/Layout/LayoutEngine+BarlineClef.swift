#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

// MARK: - A clef change at a barline

/// A clef a bar opens with is drawn at the END of the bar before it — small, before the barline — and not in its own
/// header, as MuseScore draws a clef change at a barline: `Score::undoChangeClef` moves a clef written at the start of
/// a bar to the end of the previous one (its `moveClef` path), unless there is no previous bar or it ends a section.
///
/// The bar that opens a system still draws the clef in its own header, full size — every system head shows the clef
/// in force — and the bar ending the previous system draws it small before its barline as well, which is MuseScore's
/// courtesy clef. So the bar before always draws the following clef, and only a mid-system bar leaves its own out.
///
/// The model is untouched: the clef stays in the leading run of the bar it governs, and both glyphs name it there.
extension LayoutEngine {
    /// The clef one staff's bar opens with — before its first chord or rest, in voice 0 — as the bar before it draws
    /// it: what it is, where it lives (its element index in that voice), and whether it is drawn at all.
    struct FollowingClef: Equatable, Sendable {
        let rawType: String
        let elementIndex: Int
        let visible: Bool
    }

    /// Whether the clefs bar `measureIdx` opens with belong at the end of the bar before it: there is one, and it
    /// does not end a section. With `plan`, also not a bar inside a multi-measure rest, which draws nothing — the bar
    /// after a collapsed run keeps its clef in its own header.
    ///
    /// Independent of where systems break: a system head draws the clef in its header AS WELL, which its caller
    /// decides (`buildSystem`'s `drawsLeadingClef`).
    static func leadingClefDrawnBefore(
        measureIdx: Int, staves: [Staff], plan: MultiMeasureRestPlan?,
    ) -> Bool {
        guard measureIdx > 0, let canonical = staves.first, canonical.measures.indices.contains(measureIdx - 1)
        else { return false }
        if canonical.measures[measureIdx - 1].sectionBreak { return false }
        if let plan, plan.runLength(startingAt: measureIdx - 1) != nil || plan.isInteriorOfRun(measureIdx - 1) {
            return false
        }
        return true
    }

    /// The clef `staff`'s bar `measureIdx + 1` opens with, or `nil` when it opens with none or there is no such bar.
    static func followingClef(after measureIdx: Int, in staff: Staff) -> FollowingClef? {
        let next = measureIdx + 1
        guard staff.measures.indices.contains(next), let voice = staff.measures[next].voices.first else { return nil }
        var found: FollowingClef?
        for (index, element) in voice.elements.enumerated() {
            switch element {
            case let .clef(clef):
                found = FollowingClef(rawType: clef.concertClefType, elementIndex: index, visible: clef.visible)
            case .chord:
                return found
            default:
                continue
            }
        }
        return found
    }

    /// Every staff's `followingClef(after:in:)` where bar `measureIdx + 1`'s clefs are drawn at the end of
    /// `measureIdx` (`leadingClefDrawnBefore`), `nil` per staff otherwise — what the cache keys a measure's width
    /// and a system's trailing edge by, since neither measure nor system holds the bar these clefs live in.
    static func followingClefs(
        after measureIdx: Int, staves: [Staff], plan: MultiMeasureRestPlan?,
    ) -> [FollowingClef?] {
        guard leadingClefDrawnBefore(measureIdx: measureIdx + 1, staves: staves, plan: plan) else {
            return staves.map { _ in nil }
        }
        return staves.map { followingClef(after: measureIdx, in: $0) }
    }
}
