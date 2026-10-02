import SheetMusicFoundation

/// The staff and system texts a range carries, addressed two ways: as the removals a Cut applies, and as the identities
/// a renderer lights with the range.
///
/// Both answers start from the copy's own resolution of a range's texts (`RangeCopySource.texts(for:in:)`), so what a
/// range lights, what ⌘C puts on the clipboard and what ⌘X removes are one set. Split out of `RangeCopyPayload.swift`,
/// which sits at its 400-line ceiling.
extension Score {
    /// The `.setStaffText(anchor:text: nil, isSystemText:)` removals for every staff or system text a range copy
    /// of `range` carries. Each removal is anchored at a chord or rest onset: on the text's own staff for staff
    /// text, and on a covered staff (canonical first) for system text. Text with no such onset is omitted.
    public func rangeTextRemovals(for range: VoiceElementRange) -> [EditIntent] {
        guard let extent = RangeCopySource.Extent(range: range, in: self),
              let source = try? RangeCopySource(extent: extent, in: self, operation: "CopyRange")
        else { return [] }
        // One removal per (anchor, kind): `SetStaffText`'s removal drops EVERY match on that beat and refuses when
        // there is none, so a second removal for a second "pizz." on the same beat — routine in an imported file —
        // would refuse, and with it the whole composite the host's Cut is built from.
        var removed: Set<RangeTextRemovalKey> = []
        return source.texts.compactMap { copied in
            let candidateStaves: [StaffAddress]
            if let staff = copied.staff {
                candidateStaves = [staff]
            } else {
                candidateStaves = extent.staves.contains(Self.canonicalStaff)
                    ? [Self.canonicalStaff] + extent.staves.filter { $0 != Self.canonicalStaff }
                    : extent.staves
            }
            guard let anchor = candidateStaves.lazy.compactMap({ staff in
                chordOrRest(at: copied.absoluteTick, on: staff)
            }).first,
                removed.insert(RangeTextRemovalKey(anchor: anchor, isSystemText: copied.text.isSystemText)).inserted
            else { return nil }
            return .setStaffText(
                anchor: anchor, text: nil, isSystemText: copied.text.isSystemText,
            )
        }
    }

    /// The identity of every staff or system text a range copy of `range` carries, named as the layout names it
    /// (`LayoutElement.textID`), so a renderer can light those texts together with the range's notes and rests.
    ///
    /// **The anchor is the layout's, not the removal's.** The layout draws a lane text on the staff it belongs to — a
    /// system text on `Score.canonicalStaff` — and hangs it on the lowest-numbered voice's chord or rest at its beat
    /// on that staff. So that is the only staff searched here, with no fallback to another covered staff the way
    /// `rangeTextRemovals(for:)` falls back. A text with no onset under it has no identity in the layout either, and
    /// is left out.
    ///
    /// Unlike the copy itself, this does not refuse a range that cuts a tuplet. It answers which texts the range
    /// covers, the same question `Score.items(inRangeFrom:to:)` answers for notes and rests, and that range is tinted
    /// whether or not a copy of it would be refused.
    public func rangeTextIDs(for range: VoiceElementRange) -> Set<ScoreTextID> {
        guard let extent = RangeCopySource.Extent(range: range, in: self),
              let texts = RangeCopySource.texts(for: extent, in: self)
        else { return [] }
        return Set(texts.compactMap { copied in
            guard let anchor = chordOrRest(at: copied.absoluteTick, on: copied.staff ?? Self.canonicalStaff)
            else { return nil }
            return .staffText(anchor: anchor, style: copied.text.isSystemText ? .systemText : .staffText)
        })
    }

    /// `rangeTextIDs(for:)` for a range stated the way a selection states it, by the two items at its corners — the
    /// form `items(inRangeFrom:to:)` takes, which this is the text half of.
    public func rangeTextIDs(inRangeFrom anchor: ScoreItemID, to target: ScoreItemID) -> Set<ScoreTextID> {
        rangeTextIDs(for: VoiceElementRange(start: VoiceElementID(anchor), end: VoiceElementID(target)))
    }

    /// The lowest-index voice's chord or rest at `absoluteTick` on `staff`, using the same cursor arithmetic as
    /// `Score.onset(of:)`. A lane text between chord/rest onsets intentionally has no edit-intent anchor.
    private func chordOrRest(at absoluteTick: Int, on staff: StaffAddress) -> VoiceElementID? {
        guard let staffValue = self[staff] else { return nil }
        let geometry = RangeCopyGeometry(staff: staff, in: self)
        guard let destination = geometry.position(atAbsolute: absoluteTick),
              staffValue.measures.indices.contains(destination.measure)
        else { return nil }
        let measure = staffValue.measures[destination.measure]
        let durations = effectiveMeasureDurations(
            partIndex: staff.partIndex, staffIndex: staff.staffIndexInPart,
        )
        guard durations.indices.contains(destination.measure) else { return nil }
        for (voiceIndex, voice) in measure.voices.enumerated() {
            var tick = geometry.measureStarts[destination.measure]
            for (elementIndex, element) in voice.elements.enumerated() {
                if tick == absoluteTick, case .chord = element {
                    return VoiceElementID(
                        staff: staff, measureIndex: destination.measure,
                        voiceIndex: voiceIndex, elementIndex: elementIndex,
                    )
                }
                tick += element.cursorAdvance(
                    division: division, in: durations[destination.measure],
                )
            }
        }
        return nil
    }
}

/// What `Score.rangeTextRemovals(for:)` dedupes on: one removal per anchor and kind.
private struct RangeTextRemovalKey: Hashable {
    let anchor: VoiceElementID
    let isSystemText: Bool
}
