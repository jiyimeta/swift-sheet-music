#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutDocument {
    /// The final document-space origin of a chord stem or rest at `anchor`.
    /// Used only as a deterministic empty-editor fallback when no pending
    /// engraved text exists yet.
    public func timedElementOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        if let chord = chordStemOrigin(at: anchor) {
            return chord
        }
        let restID = RestID(
            staff: anchor.staff,
            measureIndex: anchor.measureIndex,
            voiceIndex: anchor.voiceIndex,
            elementIndex: anchor.elementIndex,
        )
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == anchor.measureIndex
            {
                for element in measure.elements {
                    guard case let .rest(_, origin, _, candidate, _) = element,
                          candidate == restID
                    else { continue }
                    return absolute(
                        origin, in: system, measure: measure,
                    )
                }
            }
        }
        return nil
    }

    /// The final document-space origin of the staff- or system-text glyph anchored at `anchor`.
    ///
    /// Matched on the identity `placeMeasureElements` carried onto the element, not on the string it prints:
    /// two "solo"s in one bar are two marks, and a lookup that could only compare text had to rank them by
    /// proximity and could pick the wrong one. `style` still narrows the search because one beat can carry both
    /// a staff text and a system text — `SetStaffText` writes them as distinct marks at the same anchor.
    ///
    /// ## What `nil` means, and the two anchors that cannot match
    ///
    /// `nil` is not "the mark is not engraved". A caller re-editing an EXISTING, non-empty mark has nothing to
    /// fall back on — the empty-editor fallback in the example overlay is gated on the editor being empty
    /// (`ScoreTextEntryOverlay.textEntryOrigin`) — so a miss here shows up as NO CARET AT ALL, not as a caret
    /// in a worse place. The text-and-proximity lookup this replaced always returned something, so these two
    /// cases are a regression in exchange for never returning the wrong element; both need a beat-shaped
    /// identity to fix properly, and both are worth checking before this is relied on for a new caret path.
    ///
    /// 1. **Another voice at the same beat.** A lane mark has no voice: `SetStaffText` reduces any anchor it is
    ///    given to a `MeasurePosition`. Layout must still name one voice element, and picks the lowest-numbered
    ///    voice with a chord or rest at that beat. Pass an anchor from voice 2 of a bar whose beat also has a
    ///    voice-1 chord and this returns `nil`; the voice-1 anchor for the same mark answers.
    /// 2. **A system text queried from any staff but the canonical one.** `SetStaffText` writes a system text
    ///    with `originalStaff: nil` (it belongs to no staff), and `LayoutEngine` places a staff-less lane
    ///    element on the canonical staff only — one glyph, carrying a staff-(0,0) anchor. So
    ///    `staffTextOrigin(at:style: .systemText)` returns `nil` for EVERY anchor outside part 0 / staff 0,
    ///    which in a multi-part score is most of them.
    public func staffTextOrigin(
        at anchor: VoiceElementID,
        style: TextStyleType,
    ) -> CGPoint? {
        firstOrigin(inMeasure: anchor.measureIndex) { element in
            guard case let .staffText(
                _, origin, _, candidateStyle, candidateAnchor,
            ) = element,
                candidateAnchor == anchor,
                candidateStyle == style
            else { return nil }
            return origin
        }
    }

    /// The final document-space leading origin of the chord symbol on the chord or rest at `anchor`.
    ///
    /// Identity-matched for `staffTextOrigin(at:style:)`'s reason. `LayoutHarmony.anchor` names the element the
    /// symbol is written against, which is the same `VoiceElementID` `SetChordSymbol` takes.
    public func harmonyOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        firstOrigin(inMeasure: anchor.measureIndex) { element in
            guard case let .harmony(harmony) = element,
                  harmony.anchor == anchor
            else { return nil }
            return CGPoint(
                x: CGFloat(harmony.anchorX),
                y: CGFloat(harmony.y),
            )
        }
    }

    /// The final document-space origin of the rehearsal-mark text itself.
    ///
    /// A rehearsal mark's layout origin belongs to its frame. The renderer moves the bottom-leading text origin
    /// inward by the frame padding, so this accessor applies that same offset for an inline editing caret.
    ///
    /// The two `measureIndex` checks below are not redundant in intent, though they are in effect today. The
    /// outer `where` narrows the scan to one bar's layout measures and is load-bearing: **do not remove it.**
    /// The inner one asks the mark itself which bar it is for, so the lookup does not depend on the fact that
    /// the engine currently files a mark under exactly the bar it was emitted for — one wiring point passes the
    /// same `measureIdx` to both, so the second check is a tautology at present and is here to stay true if
    /// that ever stops holding.
    public func rehearsalMarkTextOrigin(
        at anchor: VoiceElementID,
    ) -> CGPoint? {
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == anchor.measureIndex
            {
                for element in measure.elements {
                    guard case let .rehearsalMark(
                        _, origin, _, _, candidateMeasureIndex,
                    ) = element, candidateMeasureIndex == anchor.measureIndex
                    else { continue }
                    let padding = RehearsalMarkFrame.paddingSp(sp: system.sp)
                    return absolute(
                        CGPoint(
                            x: origin.x + padding,
                            y: origin.y - padding,
                        ),
                        in: system,
                        measure: measure,
                    )
                }
            }
        }
        return nil
    }

    /// The document-space origin of the first element of `measureIndex` that `origin` answers for.
    ///
    /// Scoped to one bar because that is where a text-entry caret's anchor lives; systems are walked in order
    /// so a bar an unwound repeat laid out twice answers with its first copy.
    private func firstOrigin(
        inMeasure measureIndex: Int,
        origin: (LayoutElement) -> CGPoint?,
    ) -> CGPoint? {
        for system in systems {
            for measure in system.measures
                where measure.measureIndex == measureIndex
            {
                for element in measure.elements {
                    guard let local = origin(element) else { continue }
                    return absolute(local, in: system, measure: measure)
                }
            }
        }
        return nil
    }

    private func absolute(
        _ origin: CGPoint,
        in system: LayoutSystem,
        measure: LayoutMeasure,
    ) -> CGPoint {
        CGPoint(
            x: system.origin.x + measure.origin.x + origin.x,
            y: system.origin.y + measure.origin.y + origin.y,
        )
    }
}
