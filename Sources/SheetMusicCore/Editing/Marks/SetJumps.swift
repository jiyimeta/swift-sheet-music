import SheetMusicFoundation

/// Replaces the navigation jumps (D.C., D.S. al Coda, …) of one measure column. The list lives on the canonical
/// staff's `Measure` (`Score.canonicalStaff`, spec 2026-09-02 §3.1), where MuseScore writes it under
/// `writeSystemElements` and where `MeasureFlagsHoist` keeps it across part removals and moves; playback reads it
/// from there. An empty list clears. The inverse carries the pre-image list, so undo is byte-exact.
public struct SetJumps: EditCommand {
    public let measure: MeasureRef
    public let jumps: [Jump]

    public init(at measure: MeasureRef, jumps: [Jump]) {
        self.measure = measure
        self.jumps = jumps
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: Score.canonicalStaff, measureIndex: measure.measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard var target = score[measure: measure, staff: Score.canonicalStaff] else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let inverse = SetJumps(at: measure, jumps: target.jumps)
        target.jumps = jumps
        score[measure: measure, staff: Score.canonicalStaff] = target
        return inverse
    }
}

/// Replaces the navigation markers (segno, coda, Fine, To Coda, …) of one measure column, on the canonical
/// staff's `Measure` for the reason `SetJumps` gives. Plural because a bar legitimately carries more than one
/// (segno + coda), and replacing the list is the only semantics with a bit-perfect inverse.
public struct SetMarkers: EditCommand {
    public let measure: MeasureRef
    public let markers: [Marker]

    public init(at measure: MeasureRef, markers: [Marker]) {
        self.measure = measure
        self.markers = markers
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: Score.canonicalStaff, measureIndex: measure.measureIndex, voiceIndex: 0, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard var target = score[measure: measure, staff: Score.canonicalStaff] else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let inverse = SetMarkers(at: measure, markers: target.markers)
        target.markers = markers
        score[measure: measure, staff: Score.canonicalStaff] = target
        return inverse
    }
}
