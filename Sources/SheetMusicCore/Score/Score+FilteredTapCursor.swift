import SheetMusicFoundation

extension Score {
    /// `nearestCursor` and `editingHitTest` run against a `LayoutDocument` built from the filtered score,
    /// so the `StaffAddress` they stamp onto `NoteID` / `RestID` / `TupletID` is positional within the
    /// filtered parts. The playback engine's timeline — and every edit intent — is keyed by the full-score
    /// address, so a tap-derived cursor must be re-addressed before being handed to the engine. `.beat`
    /// cursors carry no staff address and pass through unchanged.
    public func engineCursorForFilteredTap(
        _ cursor: ScoreCursor, hiddenStaves hidden: Set<StaffAddress>,
    ) -> ScoreCursor {
        guard !hidden.isEmpty,
              case let .item(id) = cursor,
              let full = unfilterStaffAddress(id.staff, hidingStaves: hidden)
        else { return cursor }
        switch id {
        case let .note(noteID):
            return .item(.note(NoteID(
                staff: full, measureIndex: noteID.measureIndex, voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex, noteIndexInChord: noteID.noteIndexInChord,
            )))
        case let .rest(restID):
            return .item(.rest(RestID(
                staff: full, measureIndex: restID.measureIndex, voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
            )))
        case let .tuplet(tupletID):
            return .item(.tuplet(TupletID(
                staff: full, measureIndex: tupletID.measureIndex, voiceIndex: tupletID.voiceIndex,
                startElementIndex: tupletID.startElementIndex,
            )))
        case .clef:
            // Deliberately NOT re-addressed — but only because nothing produces a `.clef` cursor today:
            // `editingHitTest` drops clef hits (no clef editing UI in v1) and the playback engine never
            // parks on one. The day clef selection becomes real, `.clef` must be re-stamped here exactly
            // like `.tuplet` above — an un-re-addressed pass-through is what made a tuplet tap name the
            // wrong staff once a hidden staff sat ahead of it.
            return cursor
        }
    }

    /// Inverse of the part/staff renumbering performed by `filtered(hidingStaves:)`: given a
    /// `StaffAddress` produced against the filtered score, returns the corresponding address in this
    /// (unfiltered) score, or `nil` when the filtered address can't be located under the current
    /// visibility.
    public func unfilterStaffAddress(
        _ filtered: StaffAddress, hidingStaves hidden: Set<StaffAddress>,
    ) -> StaffAddress? {
        guard !hidden.isEmpty else { return filtered }
        var newPartIdx = 0
        for (origPartIdx, part) in parts.enumerated() {
            let surviving = part.staves.indices.filter { sIdx in
                !hidden.contains(StaffAddress(partIndex: origPartIdx, staffIndexInPart: sIdx))
            }
            guard !surviving.isEmpty else { continue }
            if newPartIdx == filtered.partIndex {
                guard surviving.indices.contains(filtered.staffIndexInPart) else { return nil }
                return StaffAddress(
                    partIndex: origPartIdx, staffIndexInPart: surviving[filtered.staffIndexInPart],
                )
            }
            newPartIdx += 1
        }
        return nil
    }

    /// Inverse of `unfilterStaffAddress`: given a full-score `StaffAddress`, return its position in the
    /// filtered score, or `nil` when the staff is itself hidden (or its enclosing part is fully hidden).
    ///
    /// The playback engine emits cursors keyed by full-score addresses, but a `LayoutDocument` built from
    /// `filtered(hidingStaves:)` stamps filtered addresses onto its `NoteID` / `RestID` keys. A playback
    /// cursor on a visible staff whose full address differs from its filtered one (any time an earlier staff
    /// in the same part is hidden, or an earlier part is fully hidden) must be re-stamped, or the layout
    /// lookup silently misses and the cursor disappears.
    public func filterStaffAddress(
        _ full: StaffAddress, hidingStaves hidden: Set<StaffAddress>,
    ) -> StaffAddress? {
        guard !hidden.isEmpty else { return full }
        guard !hidden.contains(full) else { return nil }
        var newPartIdx = 0
        for (origPartIdx, part) in parts.enumerated() {
            let surviving = part.staves.indices.filter { sIdx in
                !hidden.contains(StaffAddress(partIndex: origPartIdx, staffIndexInPart: sIdx))
            }
            guard !surviving.isEmpty else { continue }
            if origPartIdx == full.partIndex {
                guard let newStaffIdx = surviving.firstIndex(of: full.staffIndexInPart) else { return nil }
                return StaffAddress(partIndex: newPartIdx, staffIndexInPart: newStaffIdx)
            }
            newPartIdx += 1
        }
        return nil
    }

    /// Translates an engine (full-score) playback cursor into the filtered layout's coordinate space so a
    /// `LayoutDocument` built from `filtered(hidingStaves:)` can resolve its frame. When the engine emits
    /// `.item(id)`:
    ///
    /// * if the cursor's staff is hidden, translate to `.beat(measureIndex:tickInMeasure:)` so the renderer
    ///   falls back to interpolated X against the surviving visible columns;
    /// * if the staff is visible but its full-score address differs from its filtered address, re-stamp the
    ///   `NoteID` / `RestID` / `TupletID` with the filtered address.
    ///
    /// `.beat` cursors and visible-staff `.item` values whose full and filtered addresses already match pass
    /// through unchanged. This is the playback-side mirror of `engineCursorForFilteredTap` (tap → engine).
    public func translateCursorForHiddenStaves(
        _ cursor: ScoreCursor?, hiddenStaves hidden: Set<StaffAddress>,
    ) -> ScoreCursor? {
        guard let cursor else { return nil }
        guard !hidden.isEmpty, case let .item(id) = cursor else { return cursor }
        if hidden.contains(id.staff) {
            guard let tick = resolveTickInMeasure(for: id) else { return cursor }
            return .beat(measureIndex: id.measureIndex, tickInMeasure: tick)
        }
        guard let filteredStaff = filterStaffAddress(id.staff, hidingStaves: hidden),
              filteredStaff != id.staff
        else { return cursor }
        switch id {
        case let .note(noteID):
            return .item(.note(NoteID(
                staff: filteredStaff, measureIndex: noteID.measureIndex, voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex, noteIndexInChord: noteID.noteIndexInChord,
            )))
        case let .rest(restID):
            return .item(.rest(RestID(
                staff: filteredStaff, measureIndex: restID.measureIndex, voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
            )))
        case let .tuplet(tupletID):
            return .item(.tuplet(TupletID(
                staff: filteredStaff, measureIndex: tupletID.measureIndex, voiceIndex: tupletID.voiceIndex,
                startElementIndex: tupletID.startElementIndex,
            )))
        case .clef:
            // Same deliberate gap as `engineCursorForFilteredTap`'s `.clef` case (see the comment there):
            // no producer exists, and any future one must re-stamp instead of passing through.
            return cursor
        }
    }
}
