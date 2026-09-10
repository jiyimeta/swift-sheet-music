import SheetMusicFoundation

/// Sets `Staff.defaultClefType` for the staff at `staff`.
///
/// `nil` clears the default. The inverse command restores the
/// previous value (including `nil`).
public struct SetStaffDefaultClef: EditCommand {
    public let staff: StaffAddress
    public let newRawType: String?

    public init(staff: StaffAddress, newRawType: String?) {
        self.staff = staff
        self.newRawType = newRawType
    }

    /// Synthetic anchor at the start of the staff. The staff-default
    /// clef has no element location of its own; this satisfies the
    /// `EditCommand` contract for diagnostics / logging.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: staff, measureIndex: 0,
            voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices
                  .contains(staff.staffIndexInPart)
        else {
            throw Self.refused(.staffNotFound(staff))
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        let previous = score.parts[p].staves[s].defaultClefType
        score.parts.updateValue(at: p) { partValue in
            partValue.staves.updateValue(at: s) { staffValue in
                staffValue.defaultClefType = newRawType
            }
        }
        return SetStaffDefaultClef(staff: staff, newRawType: previous)
    }
}
