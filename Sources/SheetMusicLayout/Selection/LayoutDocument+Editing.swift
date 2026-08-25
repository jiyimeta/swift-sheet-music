#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

// MARK: - Hit testing

/// The editing hit-test policy that sits on top of `ScoreHitTester`'s raw ladder — which targets are
/// selectable, how much slop a fingertip gets, and when a near miss should be rescued versus treated as a tap on
/// empty paper. Moved into this library in 1.11.0 so iOS and Android run one policy instead of each platform
/// reimplementing it.
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

    /// Whether `point` is close enough to a staff for the near-miss rescue to mean anything: inside the staff's own
    /// drawn lines, or within the same slop the rescue itself reaches, so ledger-line notes and stems still count.
    /// Anything further out — page margins, the gap between systems — is empty paper, where a tap means "nothing"
    /// rather than "whatever note is nearest".
    ///
    /// Measured per staff, through `StaffLineGeometry.barLineSpanY(sp:)`. The score-global
    /// `StaffMetrics.staffHeight` is 4 sp for every staff, which is the height of a FIVE-line one: against a 3-line
    /// staff that band reached 2 sp past the bottom line, and since staves now stack by their own line count, that
    /// overshoot lands on the next staff's paper and lets a tap there be rescued to a note in it.
    ///
    /// Deliberately measured with `editingSlopHalfExtent`, the same number the box uses: a gate tighter than the box
    /// it guards would refuse rescues the box was built to make, and a looser one would let the rescue reach where
    /// the box can't.
    private func isOnStaff(_ point: CGPoint) -> Bool {
        for system in systems {
            for (flatIndex, origin) in system.staffOrigins.enumerated() {
                let span = system.geometry(atFlatIndex: flatIndex).barLineSpanY(sp: metrics.sp)
                let staffTop = system.origin.y + origin.y
                if point.y >= staffTop + span.top - Self.editingSlopHalfExtent,
                   point.y <= staffTop + span.bottom + Self.editingSlopHalfExtent
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

// MARK: - Caret geometry

extension LayoutDocument {
    /// The insertion caret's column: the engine's cursor frame for `item`, narrowed to `item`'s own staff band —
    /// one `sp` above the staff top to one `sp` below its bottom. Narrowed, unlike the playback head, because
    /// editing happens in one staff at a time.
    ///
    /// A `.tuplet` item has no laid-out column of its own (`CursorFrame.itemX` deliberately answers `nil` for
    /// brackets — they are display-only selection targets, not playback tick anchors), so its caret anchors to
    /// the column of the bracket's FIRST member chord/rest instead — the same element a selection expansion
    /// starts from, and where an edit targeting the tuplet lands. The wasm editing spec (§7.1) requires a
    /// selected tuplet to caret like any other selectable item.
    ///
    /// `nil` when the item doesn't resolve to a laid-out frame (a stale ID right after an edit reflows the
    /// document) or names a staff/measure this document doesn't contain.
    ///
    /// `minimumWidth` is the floor a zero-width frame is widened to: 2 for the caret, 1 for the selection anchor
    /// the callout is positioned from — the only difference between the two call sites in Folino's overlay.
    public func editingCaretRect(
        for item: ScoreItemID, in score: Score, minimumWidth: CGFloat = 2,
    ) -> CGRect? {
        guard let anchor = Self.caretAnchor(for: item, in: score),
              let frame = cursorFrame(for: .item(anchor), in: score),
              let band = staffBand(for: item.staff, measureIndex: item.measureIndex)
        else { return nil }
        return CGRect(x: frame.minX, y: band.top, width: max(frame.width, minimumWidth), height: band.height)
    }

    /// The item whose laid-out column anchors `item`'s caret. Notes and rests (and clefs, which never resolve
    /// anyway) anchor to themselves; a `.tuplet` anchors to the chord/rest at its `startElementIndex` — see
    /// `editingCaretRect`'s doc comment. `nil` when a tuplet's start element can't be resolved to a chord/rest
    /// in `score` (a stale ID after an edit), which `editingCaretRect` folds into its existing stale-ID `nil`.
    private static func caretAnchor(for item: ScoreItemID, in score: Score) -> ScoreItemID? {
        guard case let .tuplet(tid) = item else { return item }
        guard let staff = score[tid.staff],
              staff.measures.indices.contains(tid.measureIndex)
        else { return nil }
        let voices = staff.measures[tid.measureIndex].voices
        guard voices.indices.contains(tid.voiceIndex) else { return nil }
        let elements = voices[tid.voiceIndex].elements
        guard elements.indices.contains(tid.startElementIndex),
              case let .chord(chord) = elements[tid.startElementIndex]
        else { return nil }
        if chord.notes.isEmpty {
            return .rest(RestID(
                staff: tid.staff, measureIndex: tid.measureIndex,
                voiceIndex: tid.voiceIndex, elementIndex: tid.startElementIndex,
            ))
        }
        return .note(NoteID(
            staff: tid.staff, measureIndex: tid.measureIndex, voiceIndex: tid.voiceIndex,
            elementIndex: tid.startElementIndex, noteIndexInChord: 0,
        ))
    }

    /// Vertical band (document coords) spanning `staff`'s own drawn lines, one `sp` clear on each side, within the
    /// `LayoutSystem` that contains `measureIndex`. `nil` when the staff/measure can't be located.
    ///
    /// The span comes from `StaffLineGeometry.barLineSpanY(sp:)` rather than a fixed 4 sp, so the band tracks the
    /// staff a caret is actually in: 6 sp about the top line for five lines (unchanged), 4 sp for three, and — since
    /// a one-line staff's own height is zero — the ±2 sp MuseScore gives its barline, which keeps the caret a
    /// visible column instead of collapsing it to a 2 sp sliver a notehead pokes out of on both sides.
    private func staffBand(for staff: StaffAddress, measureIndex: Int) -> (top: CGFloat, height: CGFloat)? {
        guard let system = systems.first(where: { candidate in
            candidate.measures.contains { $0.measureIndex == measureIndex }
        }), let flatIndex = system.flatIndex(for: staff) else { return nil }
        let sp = metrics.sp
        let staffTop = system.origin.y + system.staffOrigins[flatIndex].y
        let span = system.geometry(atFlatIndex: flatIndex).barLineSpanY(sp: sp)
        return (top: staffTop + span.top - sp, height: span.bottom - span.top + 2 * sp)
    }
}
