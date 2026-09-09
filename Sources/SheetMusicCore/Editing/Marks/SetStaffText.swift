import SheetMusicFoundation

/// Writes, renames or (with `nil`) removes the staff text — or, with `isSystemText`, the system text — at the beat
/// of the chord or rest at `anchor`.
///
/// Both kinds live in the system lane (`SystemElement.staffText`); what tells them apart is `isSystemText` and,
/// for staff text, the staff it belongs to: a staff text is "the one here" when its `originalStaff` (or the
/// canonical staff, which is where a nil one is written) is the anchor's staff, so "pizz." on the flute and
/// "arco" on the cello at the same beat are two marks. A system text is one per beat whatever staff a file
/// happened to carry it under. A fresh staff text is stamped with the anchor's staff, a fresh system text with
/// no staff, which is how the encoder decides which `<Staff>` to write it into.
///
/// The text is trimmed; empty after trimming is refused as `.emptyStaffText`. A rename mutates the mark in
/// place, so its color, offsets and font overrides survive, and collapses any second match; the removal drops
/// every match and is refused when there is none. The inverse carries the pre-image lane (`SetTempo`'s idiom).
public struct SetStaffText: EditCommand {
    public let anchor: VoiceElementID
    /// The text to write, trimmed by `apply`; `nil` removes. Ignored on the restore path.
    public let text: String?
    public let isSystemText: Bool
    let restoredLane: IdentifiedArray<SystemMeasure>?

    public init(anchor: VoiceElementID, text: String?, isSystemText: Bool) {
        self.anchor = anchor
        self.text = text
        self.isSystemText = isSystemText
        restoredLane = nil
    }

    init(restoringLane lane: IdentifiedArray<SystemMeasure>, anchor: VoiceElementID, isSystemText: Bool) {
        self.anchor = anchor
        text = nil
        self.isSystemText = isSystemText
        restoredLane = lane
    }

    public var affectedLocation: VoiceElementID {
        anchor
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        // The restore branch is decided BEFORE the anchor is resolved, for `SetTempo`'s reason: the pre-image
        // lane needs no beat, and an inverse must never refuse.
        let previous = score.systemMeasures
        if let restoredLane {
            score.systemMeasures = restoredLane
            return SetStaffText(restoringLane: previous, anchor: anchor, isSystemText: isSystemText)
        }
        guard let position = SystemLaneSlot.position(of: anchor, in: score) else {
            throw Self.refused(.targetNotFound(anchor))
        }
        if let text {
            let trimmed = text.trimmingWhitespaceAndNewlines()
            guard !trimmed.isEmpty else { throw Self.refused(.emptyStaffText) }
            RehearsalMarkLane.pad(&score, ids: &ids)
            score.systemMeasures.updateValue(at: anchor.measureIndex) { write(trimmed, at: position, into: &$0) }
        } else {
            guard Self.current(at: anchor, isSystemText: isSystemText, in: score) != nil else {
                throw Self.refused(.targetNotFound(anchor))
            }
            score.systemMeasures.updateValue(at: anchor.measureIndex) { measure in
                measure.elements.removeAll {
                    $0.position == position && matches($0)
                }
            }
        }
        return SetStaffText(restoringLane: previous, anchor: anchor, isSystemText: isSystemText)
    }

    /// The text at the anchor's beat of this kind (and, for staff text, on the anchor's staff), or `nil`.
    static func current(at anchor: VoiceElementID, isSystemText: Bool, in score: Score) -> String? {
        laneMark(at: anchor, isSystemText: isSystemText, in: score)?.text
    }

    /// The mark itself rather than its string — what `SetTextVisible` reads, since it wants a field the text
    /// alone does not carry. One spelling of the lookup for both, so "which lane element does this anchor name"
    /// cannot come out differently for a rename and for a hide.
    static func laneMark(at anchor: VoiceElementID, isSystemText: Bool, in score: Score) -> StaffText? {
        guard let slot = laneSlot(at: anchor, isSystemText: isSystemText, in: score),
              case let .staffText(text) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex]
                  .element
        else { return nil }
        return text
    }

    /// Where the mark this anchor names sits in the lane: its bar, and its index within that bar's elements.
    /// `nil` when the beat carries no text of this kind. The index is what a mutation needs; `laneMark` above is
    /// the read built on it.
    static func laneSlot(
        at anchor: VoiceElementID, isSystemText: Bool, in score: Score,
    ) -> (measureIndex: Int, elementIndex: Int)? {
        let probe = SetStaffText(anchor: anchor, text: nil, isSystemText: isSystemText)
        guard let position = SystemLaneSlot.position(of: anchor, in: score),
              let measure = score[system: MeasureRef(measureIndex: anchor.measureIndex)],
              let index = SystemLaneSlot.firstIndex(in: measure, at: position, where: probe.matches)
        else { return nil }
        return (anchor.measureIndex, index)
    }

    /// Whether `positioned` is a text of this command's kind, on this command's staff.
    private func matches(_ positioned: PositionedSystemElement) -> Bool {
        guard case let .staffText(text) = positioned.element, text.isSystemText == isSystemText else { return false }
        return isSystemText || (positioned.originalStaff ?? Score.canonicalStaff) == anchor.staff
    }

    private func write(_ trimmed: String, at position: MeasurePosition, into measure: inout SystemMeasure) {
        if let index = SystemLaneSlot.firstIndex(in: measure, at: position, where: matches),
           case var .staffText(existing) = measure.elements[index].element
        {
            existing.text = trimmed
            measure.elements[index].element = .staffText(existing)
            var rest = Array(measure.elements[(index + 1)...])
            rest.removeAll { $0.position == position && matches($0) }
            measure.elements.replaceSubrange((index + 1)..., with: rest)
            return
        }
        measure.elements.insert(
            PositionedSystemElement(
                position: position,
                element: .staffText(StaffText(text: trimmed, isSystemText: isSystemText)),
                originalStaff: isSystemText ? nil : anchor.staff,
            ),
            at: SystemLaneSlot.insertionIndex(in: measure, for: position),
        )
    }
}
