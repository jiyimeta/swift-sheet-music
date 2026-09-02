import SheetMusicFoundation

/// Keeps the measure-level flags on `Score.canonicalStaff` across the two structural edits that change which staff
/// that is. `RemovePart(0)` and `MovePart` re-anchor brackets and system elements already; without this pass the
/// breaks, markers, jumps and repeat flags would leave the score with the demoted staff (layout reads them from
/// `staves.first`, MSCX writes whatever each staff carries).
///
/// The move is an overwrite, not a merge — a non-canonical staff's flags are meaningless by the invariant — and the
/// callers capture both staves' pre-image columns so their inverses restore even a stray flag.
enum MeasureFlagsHoist {
    static func column(of staff: StaffAddress, in score: Score) -> [Measure.Flags] {
        score[staff]?.measures.map(\.flags) ?? []
    }

    static func write(_ column: [Measure.Flags], to staff: StaffAddress, in score: inout Score) {
        for (measureIndex, flags) in column.enumerated() {
            let ref = MeasureRef(measureIndex: measureIndex)
            guard var measure = score[measure: ref, staff: staff] else { continue }
            measure.flags = flags
            score[measure: ref, staff: staff] = measure
        }
    }

    static func move(from source: StaffAddress, to destination: StaffAddress, in score: inout Score) {
        guard source != destination, score[source] != nil, score[destination] != nil else { return }
        let moved = column(of: source, in: score)
        write(moved, to: destination, in: &score)
        write(moved.map { _ in .none }, to: source, in: &score)
    }
}
