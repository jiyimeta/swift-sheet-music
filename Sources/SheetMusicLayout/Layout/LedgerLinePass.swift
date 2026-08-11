#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Ledger-line geometry, lifted out of the renderers.
///
/// This used to live twice — `ScoreLayerBuilder+Chord.drawLedgerLines`
/// and `ScoreCanvas.drawLedgerLines` — and not at all in the Android
/// bridge. Computing it here means the staff's line count is available
/// (the renderers cannot tell which staff a `LayoutMeasure` element
/// belongs to, because measures aggregate every staff with the staff Y
/// already baked into element origins).
///
/// Mirrors MuseScore's ledger range: the first position above the staff
/// is fixed at MuseScore line −2, and the first below is line
/// `lines() * 2` — see `ChordLayout::updateLedgerLines`,
/// `rendering/score/chordlayout.cpp:1287-1311`. (The similar code in
/// `tlayout.cpp:4593` is `layoutShadowNote`, the note-input cursor
/// preview, not the engraved chord.)
public enum LedgerLinePass {
    /// Half-width of a ledger stroke, before mirror extensions.
    private static let halfWidthInSp: CGFloat = 0.9
    /// Ledger strokes are drawn heavier than staff lines.
    private static let thicknessFactor: CGFloat = 1.5

    /// Ledger strokes for one chord's notes.
    ///
    /// - Parameters:
    ///   - notes: the notes to consider. Callers pass the visible and
    ///     invisible subsets separately, because the mirror-extension
    ///     bounds are computed within whichever subset is drawn.
    ///   - metrics: already scaled by the chord's `mag`.
    ///   - firstStepAbove: `step` of the first ledger position above the
    ///     staff. Always +6 — MuseScore's line −2.
    ///   - firstStepBelow: `step` of the first ledger position below the
    ///     staff. −6 for a five-line staff; `4 - 2 * lineCount` in general.
    public static func strokes(
        for notes: [LayoutChordNote],
        stem: StemDirection,
        metrics: StaffMetrics,
        firstStepAbove: Int,
        firstStepBelow: Int,
    ) -> [LayoutElement] {
        guard let ref = notes.first else { return [] }
        let steps = notes.map(\.step)
        guard let maxStep = steps.max(), let minStep = steps.min() else { return [] }
        let needsAbove = maxStep >= firstStepAbove
        let needsBelow = minStep <= firstStepBelow
        guard needsAbove || needsBelow else { return [] }

        // `origin.y` is the notehead's Y; undo the note's own step to
        // recover the middle line, then step back out per ledger.
        let staffMidY = ref.origin.y + CGFloat(ref.step) * metrics.sp / 2
        let chordX = ref.origin.x
        let halfWidth = metrics.sp * halfWidthInSp
        let thickness = metrics.staffLineThickness * thicknessFactor

        /// A ledger crossing a mirrored notehead has to reach it, so
        /// widen that side by the mirror offset.
        func bounds(forLedgerStep ledger: Int) -> (CGFloat, CGFloat) {
            var leftExt: CGFloat = 0
            var rightExt: CGFloat = 0
            for n in notes where abs(n.step - ledger) <= 1 && n.mirror {
                let dx = n.mirrorDx(stem: stem, sp: metrics.sp)
                if dx > 0 { rightExt = max(rightExt, dx) } else { leftExt = max(leftExt, -dx) }
            }
            return (chordX - halfWidth - leftExt, chordX + halfWidth + rightExt)
        }

        func stroke(atStep ledgerStep: Int) -> LayoutElement {
            let y = staffMidY - CGFloat(ledgerStep) * metrics.sp / 2
            let (xL, xR) = bounds(forLedgerStep: ledgerStep)
            return .ledgerLine(
                from: CGPoint(x: xL, y: y),
                to: CGPoint(x: xR, y: y),
                thickness: thickness,
            )
        }

        var result: [LayoutElement] = []
        if needsAbove {
            // Snap the outermost note down onto a line position: a note
            // in the space above a ledger does not add another stroke.
            let topLine = maxStep.isMultiple(of: 2) ? maxStep : maxStep - 1
            for s in stride(from: firstStepAbove, through: topLine, by: 2) {
                result.append(stroke(atStep: s))
            }
        }
        if needsBelow {
            let botLine = minStep.isMultiple(of: 2) ? minStep : minStep + 1
            for s in stride(from: firstStepBelow, through: botLine, by: -2) {
                result.append(stroke(atStep: s))
            }
        }
        return result
    }
}

extension LedgerLinePass {
    /// Insert ledger strokes into one staff's element list, immediately
    /// before each chord so they render behind it.
    ///
    /// Visible and invisible noteheads are handled in separate batches,
    /// preserving the renderers' previous behavior: the mirror-extension
    /// bounds are computed within whichever subset is being drawn, and
    /// the caller routes the invisible batch into
    /// `LayoutMeasure.invisibleElements` for 50 % graying.
    public static func insert(
        into elements: [LayoutElement],
        metrics: StaffMetrics,
        firstStepAbove: Int,
        firstStepBelow: Int,
        invisibleNotes: Bool,
    ) -> [LayoutElement] {
        var out: [LayoutElement] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard case let .chord(
                notes, _, stem, _, _, _, _, _, _, _, mag,
            ) = element else {
                out.append(element)
                continue
            }
            let subset = notes.filter { $0.isInvisible == invisibleNotes }
            // Copied verbatim from the two renderers this pass replaces
            // (`ScoreLayerBuilder+Element` / `ScoreCanvas`): small and
            // cue noteheads scale every glyph dimension by `mag`.
            let chordMetrics = mag == 1.0
                ? metrics
                : StaffMetrics(staffSize: metrics.staffHeight * mag)
            out.append(contentsOf: strokes(
                for: subset,
                stem: stem,
                metrics: chordMetrics,
                firstStepAbove: firstStepAbove,
                firstStepBelow: firstStepBelow,
            ))
            out.append(element)
        }
        return out
    }
}
