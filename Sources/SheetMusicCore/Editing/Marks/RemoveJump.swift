import SheetMusicFoundation

/// Removes one jump from the addressed staff's measure list.
/// MSCX can store copies on other staves; those copies remain untouched.
///
/// > Note: This command is sugar over a staff-scoped read–replace–write operation. The inverse restores
/// > the full prior list. `SetJumps` cannot implement it because that setter addresses only the canonical staff.
/// > See `docs/edit-commands.md`.
public struct RemoveJump: EditCommand {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let index: Int

    public init(staff: StaffAddress, measureIndex: Int, index: Int) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.index = index
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let measure = MeasureRef(measureIndex: measureIndex)
        guard var target = score[measure: measure, staff: staff], target.jumps.indices.contains(index) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let inverse = RestoreJumpList(staff: staff, measureIndex: measureIndex, jumps: target.jumps)
        target.jumps.remove(at: index)
        score[measure: measure, staff: staff] = target
        return inverse
    }
}

private struct RestoreJumpList: EditCommand {
    let staff: StaffAddress
    let measureIndex: Int
    let jumps: [Jump]

    var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let measure = MeasureRef(measureIndex: measureIndex)
        guard var target = score[measure: measure, staff: staff] else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let inverse = RestoreJumpList(staff: staff, measureIndex: measureIndex, jumps: target.jumps)
        target.jumps = jumps
        score[measure: measure, staff: staff] = target
        return inverse
    }
}
