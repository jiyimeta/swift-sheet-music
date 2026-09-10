import SheetMusicFoundation

extension Score {
    /// Re-stamps display-only lane attachments with the same map as the surviving staves.
    /// System-wide marks stay above the first visible staff; staff-owned marks leave the
    /// display copy when their owner is hidden. The committed lane and surviving EIDs stay intact.
    mutating func filterSystemLane(survivorLocations: [StaffAddress: (part: Int, staff: Int)]) {
        for measureIndex in systemMeasures.indices {
            systemMeasures.updateValue(at: measureIndex) { measure in
                var surviving: [(EID, PositionedSystemElement)] = []
                for (index, positioned) in measure.elements.enumerated() {
                    var mapped = positioned
                    if positioned.isScoreWide {
                        mapped.originalStaff = nil
                    } else {
                        guard let location = survivorLocations[positioned.originalStaff ?? Self.canonicalStaff]
                        else { continue }
                        mapped.originalStaff = StaffAddress(partIndex: location.part, staffIndexInPart: location.staff)
                    }
                    surviving.append((measure.elements.eid(at: index), mapped))
                }
                measure.elements = IdentifiedArray(surviving)
            }
        }
    }
}

extension PositionedSystemElement {
    fileprivate var isScoreWide: Bool {
        switch element {
        case .tempo, .rehearsalMark: true
        case let .staffText(text): text.isSystemText
        case let .swing(swing): swing.isSystemText
        case .instrumentChange: false
        }
    }
}
