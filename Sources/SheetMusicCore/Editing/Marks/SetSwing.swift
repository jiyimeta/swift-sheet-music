import SheetMusicFoundation

/// Writes, edits or (with `nil`) removes the swing directive at the beat of the chord or rest at `anchor` —
/// MuseScore's "Swing" and "Straight" palette items, which are one element with two sets of defaults.
///
/// A swing directive is a SYSTEM element (`SystemElement.swing`) carrying a label, a unit and a ratio: it swings
/// everything from its beat onwards until the next one. `Swing.isSystemText` tells a system-wide directive from a
/// staff-bound one exactly as `StaffText.isSystemText` does, and the same rule decides which one an anchor names:
/// a system directive is one per beat, a staff one is per beat AND staff.
///
/// **"Straight" is this command with `unit: .off`, not a command of its own.** MuseScore's two palette cells write
/// the same element — swing writes `eighth` at 60%, straight writes the off unit — and a host editing either one
/// must be able to turn it into the other, which is what makes them one thing with two defaults rather than two
/// things.
///
/// The label is trimmed; empty after trimming is refused as `.emptyStaffText`, the refusal its sibling uses for the
/// same mistake. An edit mutates the directive in place, so its color, offsets and font overrides survive, and
/// collapses any second match at the beat; the removal drops every match and is refused when there is none. The
/// inverse carries the pre-image lane — `SetTempo`'s idiom, for its reason.
public struct SetSwing: EditCommand {
    /// What a swing directive says. Everything a host edits, and nothing about how the mark is drawn.
    public struct Settings: Hashable, Sendable {
        /// The label engraved on the page. MuseScore writes "Swing" and "Straight"; a user-edited label
        /// ("Shuffle") round-trips.
        public var text: String
        /// Which subdivision swings. `.off` straightens from this beat on, whatever the score style says.
        public var unit: SwingUnit
        /// Percent: 50 is even, 60 MuseScore's default swing, 67 ≈ 2:1, 75 a perfect triplet. Ignored while
        /// `unit` is `.off`, and preserved rather than reset so flipping a directive off and on again keeps it.
        public var ratio: Int
        /// A system-wide directive (every staff) rather than one bound to the anchor's staff.
        public var isSystemText: Bool

        public init(text: String, unit: SwingUnit, ratio: Int, isSystemText: Bool = true) {
            self.text = text
            self.unit = unit
            self.ratio = ratio
            self.isSystemText = isSystemText
        }
    }

    public let anchor: VoiceElementID
    /// The directive to write, or `nil` to remove the one at the anchor's beat. Ignored on the restore path.
    public let settings: Settings?
    /// Which kind the anchor names when `settings` is `nil` — a removal has no settings to read it from.
    public let isSystemText: Bool
    let restoredLane: IdentifiedArray<SystemMeasure>?

    public init(anchor: VoiceElementID, settings: Settings?, isSystemText: Bool = true) {
        self.anchor = anchor
        self.settings = settings
        self.isSystemText = settings?.isSystemText ?? isSystemText
        restoredLane = nil
    }

    init(restoringLane lane: IdentifiedArray<SystemMeasure>, anchor: VoiceElementID, isSystemText: Bool) {
        self.anchor = anchor
        settings = nil
        self.isSystemText = isSystemText
        restoredLane = lane
    }

    public var affectedLocation: VoiceElementID {
        anchor
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        // The restore branch is decided BEFORE the anchor is resolved, for `SetTempo`'s reason: the pre-image lane
        // needs no beat, and an inverse must never refuse.
        let previous = score.systemMeasures
        if let restoredLane {
            score.systemMeasures = restoredLane
            return SetSwing(restoringLane: previous, anchor: anchor, isSystemText: isSystemText)
        }
        guard let position = SystemLaneSlot.position(of: anchor, in: score) else {
            throw Self.refused(.targetNotFound(anchor))
        }
        if let settings {
            let trimmed = settings.text.trimmingWhitespaceAndNewlines()
            guard !trimmed.isEmpty else { throw Self.refused(.emptyStaffText) }
            RehearsalMarkLane.pad(&score, ids: &ids)
            var written = settings
            written.text = trimmed
            score.systemMeasures.updateValue(at: anchor.measureIndex) {
                write(written, at: position, into: &$0, ids: &ids)
            }
        } else {
            guard Self.current(at: anchor, isSystemText: isSystemText, in: score) != nil else {
                throw Self.refused(.targetNotFound(anchor))
            }
            score.systemMeasures.updateValue(at: anchor.measureIndex) { measure in
                measure.elements.removeAll { $0.position == position && matches($0) }
            }
        }
        return SetSwing(restoringLane: previous, anchor: anchor, isSystemText: isSystemText)
    }

    /// The directive at the anchor's beat of this kind, or `nil` — what a host reads to fill an editor.
    public static func current(at anchor: VoiceElementID, isSystemText: Bool, in score: Score) -> Settings? {
        guard let swing = laneMark(at: anchor, isSystemText: isSystemText, in: score) else { return nil }
        return Settings(
            text: swing.text, unit: swing.unit, ratio: swing.ratio, isSystemText: swing.isSystemText,
        )
    }

    /// The directive itself rather than its settings — what a color or font write addresses.
    static func laneMark(at anchor: VoiceElementID, isSystemText: Bool, in score: Score) -> Swing? {
        guard let slot = laneSlot(at: anchor, isSystemText: isSystemText, in: score),
              case let .swing(swing) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex].element
        else { return nil }
        return swing
    }

    /// Where the directive this anchor names sits in the lane: its bar, and its index within that bar's elements.
    static func laneSlot(
        at anchor: VoiceElementID, isSystemText: Bool, in score: Score,
    ) -> (measureIndex: Int, elementIndex: Int)? {
        let probe = SetSwing(anchor: anchor, settings: nil, isSystemText: isSystemText)
        guard let position = SystemLaneSlot.position(of: anchor, in: score),
              let measure = score[system: MeasureRef(measureIndex: anchor.measureIndex)],
              let index = SystemLaneSlot.firstIndex(in: measure, at: position, where: probe.matches)
        else { return nil }
        return (anchor.measureIndex, index)
    }

    /// Whether `positioned` is a swing directive of this command's kind, on this command's staff.
    private func matches(_ positioned: PositionedSystemElement) -> Bool {
        guard case let .swing(swing) = positioned.element, swing.isSystemText == isSystemText else { return false }
        return isSystemText || (positioned.originalStaff ?? Score.canonicalStaff) == anchor.staff
    }

    private func write(
        _ settings: Settings, at position: MeasurePosition, into measure: inout SystemMeasure,
        ids: inout EIDAllocator,
    ) {
        if let index = SystemLaneSlot.firstIndex(in: measure, at: position, where: matches),
           case var .swing(existing) = measure.elements[index].element
        {
            existing.text = settings.text
            existing.unit = settings.unit
            existing.ratio = settings.ratio
            measure.elements.updateValue(at: index) { $0.element = .swing(existing) }
            for duplicate in measure.elements.indices.reversed() where duplicate > index {
                let element = measure.elements[duplicate]
                if element.position == position, matches(element) {
                    measure.elements.removeSubrange(duplicate ..< duplicate + 1)
                }
            }
            return
        }
        measure.elements.insert(
            PositionedSystemElement(
                position: position,
                element: .swing(Swing(
                    text: settings.text,
                    unit: settings.unit,
                    ratio: settings.ratio,
                    isSystemText: settings.isSystemText,
                )),
                originalStaff: settings.isSystemText ? nil : anchor.staff,
            ),
            at: SystemLaneSlot.insertionIndex(in: measure, for: position),
            id: ids.next(),
        )
    }
}
