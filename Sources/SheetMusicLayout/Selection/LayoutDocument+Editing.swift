#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Task 8: the editing hit-test policy that sits on top of `ScoreHitTester`'s raw ladder — which targets are
/// selectable, how much slop a fingertip gets, and when a near miss should be rescued versus treated as a tap on
/// empty paper. Moved from Folino's `EditorViewModel+HitTest.swift` in 1.10.0 so iOS and Android run one policy.
@available(macOS 15.0, *)
extension LayoutDocument {
    /// A tap in document coordinates resolved to the item it selects, or `nil` for "nothing" — which is what a tap
    /// on empty paper must mean, so the editing pad can be put away without leaving edit mode.
    ///
    /// The caller still owns re-addressing: this answers in the RENDERED document's addressing, which may be a
    /// staff-filtered rendition of the score being edited.
    ///
    /// 1. `ScoreHitTester.hitTest(at:)` ladder (notehead → rest → beam → flag → stem → tuplet → clef).
    ///    `.stem`/`.flag`/`.beam` resolve to their first `NoteID`; `.clef` is ignored in v1 (no clef editing UI).
    /// 2. If the hit's `voiceIndex != activeVoice` and a 44x44 slop rect centered on `point` (via `itemIDs(in:)`)
    ///    contains an item of the active voice, prefer the first such item (spec §5.5 — the picker targets a
    ///    voice).
    /// 3. No hit → `nil`.
    public func editingHitTest(at point: CGPoint, activeVoice: Int) -> ScoreItemID? {
        let tester = ScoreHitTester(document: self)
        let slop = Self.slopRect(around: point)

        guard let hit = tester.hitTest(at: point), let item = Self.selectableItem(from: hit) else {
            // The engine's ladder only answers for points inside an element's own geometry, which makes noteheads a
            // fingertip-sized target at best and a hairline one on a dense system. Fall back to anything within the
            // slop box so a near miss still lands, preferring the active voice the same way an on-target hit does.
            //
            // But only ON a staff. The slop box is 44 document points — several staff spaces at a typical staff size
            // — so away from this guard it reached out of the page margins and the gaps between systems and pulled in
            // whatever note was nearest. Tapping empty paper then re-selected instead of deselecting, and there was
            // no way to put the pad away short of leaving edit mode.
            guard isOnStaff(point) else { return nil }
            let nearby = tester.itemIDs(in: slop)
            return nearby.first { $0.voiceIndex == activeVoice } ?? nearby.first
        }

        if item.voiceIndex != activeVoice {
            if let preferred = tester.itemIDs(in: slop).first(where: { $0.voiceIndex == activeVoice }) {
                return preferred
            }
        }
        return item
    }

    /// Whether `point` is close enough to a staff for the near-miss rescue to mean anything: inside the five lines,
    /// or within the same slop the rescue itself reaches, so ledger-line notes and stems still count. Anything
    /// further out — page margins, the gap between systems — is empty paper, where a tap means "nothing" rather than
    /// "whatever note is nearest".
    ///
    /// Deliberately measured with `editingSlopHalfExtent`, the same number the box uses: a gate tighter than the box
    /// it guards would refuse rescues the box was built to make, and a looser one would let the rescue reach where
    /// the box can't.
    private func isOnStaff(_ point: CGPoint) -> Bool {
        let staffHeight = metrics.staffHeight
        for system in systems {
            for origin in system.staffOrigins {
                let top = system.origin.y + origin.y
                if point.y >= top - Self.editingSlopHalfExtent,
                   point.y <= top + staffHeight + Self.editingSlopHalfExtent
                {
                    return true
                }
            }
        }
        return false
    }

    /// How close "close" is, in layout-document points — for the slop box below and for `isOnStaff` above. The JNI
    /// bridge and any future caller must not invent a second number.
    public static let editingSlopHalfExtent: CGFloat = 22

    /// Touch slop around a tap, in layout-document points. Used both to prefer the active voice on an on-target hit
    /// and to rescue a near miss — one constant so the two can't disagree about how close "close" is.
    private static func slopRect(around point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - editingSlopHalfExtent, y: point.y - editingSlopHalfExtent,
            width: editingSlopHalfExtent * 2, height: editingSlopHalfExtent * 2,
        )
    }

    /// Reduces a raw hit-test target to the `ScoreItemID` that tapping it selects. `.stem`/`.flag`/`.beam` all
    /// select the first notehead they carry (there's no dedicated selection UI for those geometric elements yet);
    /// `.clef` has no v1 editing UI and is dropped.
    private static func selectableItem(from target: ScoreHitTarget) -> ScoreItemID? {
        switch target {
        case let .note(id): .note(id)
        case let .rest(id): .rest(id)
        case let .tuplet(id): .tuplet(id)
        case let .stem(notes), let .flag(notes), let .beam(notes):
            notes.first.map(ScoreItemID.note)
        case .clef:
            nil
        }
    }
}
