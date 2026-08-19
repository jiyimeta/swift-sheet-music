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
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices
                  .contains(staff.staffIndexInPart)
        else {
            throw SheetMusicError.invalidEdit(
                reason: "SetStaffDefaultClef: no staff at \(staff)",
            )
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        let previous = score.parts[p].staves[s].defaultClefType
        score.parts[p].staves[s].defaultClefType = newRawType
        return SetStaffDefaultClef(staff: staff, newRawType: previous)
    }
}
