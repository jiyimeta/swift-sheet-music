import SheetMusicFoundation

/// Writes all staff and system texts carried beside a range's voice streams as one lane-restoring command.
/// MuseScore's paste adds these annotations at their own ticks without deleting unrelated annotations; the only
/// replacement here is `SetStaffText`'s one-text-per-kind-per-beat rule.
struct PlaceCopiedTexts: EditCommand {
    let texts: [RangeCopySource.CopiedText]
    let destinationTick: Int
    let sourceStartTick: Int
    let axis: StaffAddress
    let location: VoiceElementID
    let restoredLane: IdentifiedArray<SystemMeasure>?

    init(
        texts: [RangeCopySource.CopiedText], destinationTick: Int, sourceStartTick: Int,
        axis: StaffAddress, location: VoiceElementID,
    ) {
        self.texts = texts
        self.destinationTick = destinationTick
        self.sourceStartTick = sourceStartTick
        self.axis = axis
        self.location = location
        restoredLane = nil
    }

    private init(
        restoringLane lane: IdentifiedArray<SystemMeasure>, texts: [RangeCopySource.CopiedText],
        destinationTick: Int, sourceStartTick: Int, axis: StaffAddress, location: VoiceElementID,
    ) {
        self.texts = texts
        self.destinationTick = destinationTick
        self.sourceStartTick = sourceStartTick
        self.axis = axis
        self.location = location
        restoredLane = lane
    }

    var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let previous = score.systemMeasures
        if let restoredLane {
            score.systemMeasures = restoredLane
            return PlaceCopiedTexts(
                restoringLane: previous, texts: texts, destinationTick: destinationTick,
                sourceStartTick: sourceStartTick, axis: axis, location: location,
            )
        }

        let geometry = RangeCopyGeometry(staff: axis, in: score)
        let placements = try texts.map { copied in
            let absoluteTick = destinationTick + copied.absoluteTick - sourceStartTick
            guard let destination = geometry.position(atAbsolute: absoluteTick) else {
                throw Self.refused(.targetNotFound(location))
            }
            return (
                measureIndex: destination.measure,
                position: MeasurePosition(
                    numerator: destination.tick, denominator: 4 * score.division,
                ),
                copied: copied,
            )
        }

        RehearsalMarkLane.pad(&score, ids: &ids)
        for placement in placements {
            score.systemMeasures.updateValue(at: placement.measureIndex) { measure in
                measure.elements.removeAll {
                    $0.position == placement.position && Self.matches($0, copied: placement.copied)
                }
                let positioned = PositionedSystemElement(
                    position: placement.position,
                    element: .staffText(placement.copied.text),
                    originalStaff: placement.copied.text.isSystemText ? nil : placement.copied.staff,
                )
                measure.elements.insert(
                    positioned,
                    at: SystemLaneSlot.insertionIndex(in: measure, for: placement.position),
                    id: ids.next(),
                )
            }
        }
        return PlaceCopiedTexts(
            restoringLane: previous, texts: texts, destinationTick: destinationTick,
            sourceStartTick: sourceStartTick, axis: axis, location: location,
        )
    }

    private static func matches(
        _ positioned: PositionedSystemElement, copied: RangeCopySource.CopiedText,
    ) -> Bool {
        guard case let .staffText(existing) = positioned.element,
              existing.isSystemText == copied.text.isSystemText
        else { return false }
        if copied.text.isSystemText { return true }
        guard let staff = copied.staff else { return false }
        return (positioned.originalStaff ?? Score.canonicalStaff) == staff
    }
}
