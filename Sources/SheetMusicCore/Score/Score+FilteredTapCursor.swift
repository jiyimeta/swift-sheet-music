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
        case let .text(textID):
            return .item(.text(textID.withStaff(full)))
        case let .element(elementID):
            switch elementID {
            case let .dynamic(anchor): return .item(.element(.dynamic(anchor: anchor.withStaff(full))))
            case let .fermata(anchor): return .item(.element(.fermata(anchor: anchor.withStaff(full))))
            case let .breath(anchor): return .item(.element(.breath(anchor: anchor.withStaff(full))))
            case let .tempo(anchor): return .item(.element(.tempo(anchor: anchor.withStaff(full))))
            case let .spanner(anchor, kind):
                return .item(.element(.spanner(anchor: anchor.withStaff(full), kind: kind)))
            case let .articulation(anchor, kind):
                return .item(.element(.articulation(anchor: anchor.withStaff(full), kind: kind)))
            case let .tie(start, end):
                guard let endStaff = unfilterStaffAddress(end.staff, hidingStaves: hidden) else { return cursor }
                return .item(.element(.tie(start: start.withStaff(full), end: end.withStaff(endStaff))))
            case let .slur(.chord(anchor, ordinal)):
                return .item(.element(.slur(.chord(anchor: anchor.withStaff(full), ordinal: ordinal))))
            case let .slur(.voice(anchor)):
                return .item(.element(.slur(.voice(anchor.withStaff(full)))))
            case let .jump(_, measureIndex, index):
                return .item(.element(.jump(staff: full, measureIndex: measureIndex, index: index)))
            case let .marker(_, measureIndex, index):
                return .item(.element(.marker(staff: full, measureIndex: measureIndex, index: index)))
            case .keySignature, .timeSignature, .barLine:
                // Bar addresses have no staff field to re-stamp; this is not a deferred remapping.
                return cursor
            }
        case let .clef(anchor):
            return .item(.clef(anchor.withStaff(full)))
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
    /// Bar-addressed element identities also pass through: their approximate staff is not a field to remap.
    /// Jump and marker identities instead own a staff's list and follow the existing staff remap and
    /// hidden-owner fallback. A list index is not a voice slot; tick lookup uses voice 0 / slot 0.
    /// A tie's two endpoints are re-stamped separately, before the start-only staff guard below.
    public func translateCursorForHiddenStaves(
        _ cursor: ScoreCursor?, hiddenStaves hidden: Set<StaffAddress>,
    ) -> ScoreCursor? {
        guard let cursor else { return nil }
        guard !hidden.isEmpty, case let .item(id) = cursor else { return cursor }
        // The top-staff approximation is not an owned staff and must not trigger the hidden-staff beat fallback.
        if id.elementID?.measureIndexIfAddressedByBar != nil { return cursor }
        if hidden.contains(id.staff) {
            guard let tick = resolveTickInMeasure(for: id) else { return cursor }
            return .beat(measureIndex: id.measureIndex, tickInMeasure: tick)
        }
        if case let .element(.tie(start, end)) = id {
            return filteredTieCursor(start: start, end: end, hiding: hidden) ?? cursor
        }
        guard let filteredStaff = filterStaffAddress(id.staff, hidingStaves: hidden),
              filteredStaff != id.staff
        else { return cursor }
        switch id {
        case let .note(noteID):
            return .item(.note(noteID.withStaff(filteredStaff)))
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
        case let .text(textID):
            return .item(.text(textID.withStaff(filteredStaff)))
        case let .element(elementID):
            switch elementID {
            case let .dynamic(anchor): return .item(.element(.dynamic(anchor: anchor.withStaff(filteredStaff))))
            case let .fermata(anchor): return .item(.element(.fermata(anchor: anchor.withStaff(filteredStaff))))
            case let .breath(anchor): return .item(.element(.breath(anchor: anchor.withStaff(filteredStaff))))
            case let .tempo(anchor): return .item(.element(.tempo(anchor: anchor.withStaff(filteredStaff))))
            case let .spanner(anchor, kind):
                return .item(.element(.spanner(anchor: anchor.withStaff(filteredStaff), kind: kind)))
            case let .articulation(anchor, kind):
                return .item(.element(.articulation(anchor: anchor.withStaff(filteredStaff), kind: kind)))
            case .tie:
                // Both endpoints were handled before the start-only staff equality guard.
                return cursor
            case let .slur(.chord(anchor, ordinal)):
                return .item(.element(.slur(.chord(anchor: anchor.withStaff(filteredStaff), ordinal: ordinal))))
            case let .slur(.voice(anchor)):
                return .item(.element(.slur(.voice(anchor.withStaff(filteredStaff)))))
            case let .jump(_, measureIndex, index):
                return .item(.element(.jump(staff: filteredStaff, measureIndex: measureIndex, index: index)))
            case let .marker(_, measureIndex, index):
                return .item(.element(.marker(staff: filteredStaff, measureIndex: measureIndex, index: index)))
            case .keySignature, .timeSignature, .barLine:
                // Bar addresses have no staff field to re-stamp; this is not a deferred remapping.
                return cursor
            }
        case let .clef(anchor):
            return .item(.clef(anchor.withStaff(filteredStaff)))
        }
    }
}

extension ScoreTextID {
    /// This identity re-stamped onto `staff`, for the part/staff renumbering a filtered score performs.
    ///
    /// A rehearsal mark is returned unchanged: it is addressed by bar, carries no staff, and
    /// `ScoreItemID.staff`'s answer for it is the top-staff approximation rather than a stored value, so
    /// there is nothing to re-stamp.
    func withStaff(_ staff: StaffAddress) -> ScoreTextID {
        switch self {
        case let .lyric(anchor, verse):
            return .lyric(anchor: anchor.withStaff(staff), verse: verse)
        case let .staffText(anchor, style):
            return .staffText(anchor: anchor.withStaff(staff), style: style)
        case let .harmony(anchor):
            return .harmony(anchor: anchor.withStaff(staff))
        case .rehearsalMark:
            return self
        }
    }
}

extension ClefAnchor {
    fileprivate func withStaff(_ staff: StaffAddress) -> ClefAnchor {
        switch self {
        case let .explicit(anchor): .explicit(anchor.withStaff(staff))
        case .staffDefault: .staffDefault(staff)
        }
    }
}

extension Score {
    /// A tie's end can move even when its start does not, so each endpoint is filtered on its own. `nil` when
    /// either endpoint's staff has no filtered address; the caller keeps the cursor, as the generic staff
    /// lookup does, rather than inventing a surviving endpoint.
    private func filteredTieCursor(
        start: NoteID, end: NoteID, hiding hidden: Set<StaffAddress>,
    ) -> ScoreCursor? {
        guard let startStaff = filterStaffAddress(start.staff, hidingStaves: hidden),
              let endStaff = filterStaffAddress(end.staff, hidingStaves: hidden)
        else { return nil }
        return .item(.element(.tie(start: start.withStaff(startStaff), end: end.withStaff(endStaff))))
    }
}

extension VoiceElementID {
    fileprivate func withStaff(_ staff: StaffAddress) -> VoiceElementID {
        VoiceElementID(
            staff: staff, measureIndex: measureIndex,
            voiceIndex: voiceIndex, elementIndex: elementIndex,
        )
    }
}

extension NoteID {
    fileprivate func withStaff(_ staff: StaffAddress) -> NoteID {
        NoteID(
            staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex,
            elementIndex: elementIndex, noteIndexInChord: noteIndexInChord,
        )
    }
}
