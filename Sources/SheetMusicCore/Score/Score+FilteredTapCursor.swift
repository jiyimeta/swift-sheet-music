import Foundation

extension Score {
    /// `nearestCursor` runs against a `LayoutDocument` built from the filtered score, so the
    /// `StaffAddress` it stamps onto `NoteID` / `RestID` is positional within the filtered parts. The
    /// playback engine's timeline is keyed by the full-score address, so a tap-derived cursor must be
    /// re-addressed before being handed to the engine. `.beat` cursors carry no staff address and pass
    /// through unchanged.
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
        case .tuplet, .clef:
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
}
