import SheetMusicFoundation

/// One staff's measures laid end to end on a single tick axis, so "the same length, later" is a
/// subtraction and a measure crossing is a lookup rather than a walk.
///
/// Measure lengths are a per-staff fact (`Score.effectiveMeasureDurations(partIndex:staffIndex:)` —
/// a local time signature changes one staff's bars and not another's), which is why this is built
/// per staff rather than once for the score.
struct RangeCopyGeometry {
    /// The absolute tick each measure starts at, in measure order.
    let measureStarts: [Int]
    /// One past the last measure — the first absolute tick the staff does not have.
    let totalTicks: Int

    init(staff: StaffAddress, in score: Score) {
        let durations = score.effectiveMeasureDurations(
            partIndex: staff.partIndex, staffIndex: staff.staffIndexInPart,
        )
        var starts: [Int] = []
        starts.reserveCapacity(durations.count)
        var cursor = 0
        for duration in durations {
            starts.append(cursor)
            cursor += duration.ticks(division: score.division)
        }
        measureStarts = starts
        totalTicks = cursor
    }

    func measureLength(_ measureIndex: Int) -> Int {
        guard measureStarts.indices.contains(measureIndex) else { return 0 }
        let end = measureIndex + 1 < measureStarts.count ? measureStarts[measureIndex + 1] : totalTicks
        return end - measureStarts[measureIndex]
    }

    func absolute(_ position: ScoreTickPosition) -> Int {
        guard measureStarts.indices.contains(position.measure) else { return totalTicks }
        return measureStarts[position.measure] + position.tick
    }

    /// `nil` past the staff's last measure — the caller's signal that it must append bars before it
    /// can place anything there.
    func position(atAbsolute tick: Int) -> ScoreTickPosition? {
        guard tick >= 0, tick < totalTicks else { return nil }
        // `measureStarts` is ascending, so the owning measure is the last start at or below `tick`.
        var index = 0
        for (candidate, start) in measureStarts.enumerated() where start <= tick {
            index = candidate
        }
        return ScoreTickPosition(measure: index, tick: tick - measureStarts[index])
    }
}
