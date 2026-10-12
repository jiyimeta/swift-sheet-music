import SheetMusicFoundation

// Per-staff answers a planner reads once for a whole walk, instead of once per element. Both questions are answered
// by walking a staff from its first bar — `Score.effectiveMeasureDuration(at:measureIndex:)` builds the staff's
// whole duration table, `Score.activeKey(staff:measureIndex:)` rescans every bar up to the one asked about — so a
// walk asking once per chord is quadratic in the length of the staff. The whole-score transposition of a 130-bar,
// six-part score spent about three quarters of its time rebuilding the same duration table, and ran 37 s in a debug
// build (folino's Windows round-trip golden, 2026-10-12).
//
// A table is built from one score and answers for that score. A planner that keeps reading it while its own steps
// rewrite a working copy relies on those steps leaving time signatures, `actualLength` and key signatures where they
// were; each such planner says so where it builds its table, and asserts it in debug builds. A staff the table was
// not built for is answered from the score itself, so a table only ever saves work — it never changes an answer.

/// Each measure's effective duration on the staves a walk visits — `Score.effectiveMeasureDuration(at:measureIndex:)`
/// read off one table per staff.
struct MeasureDurationTable {
    private let score: Score
    private let durations: [StaffAddress: [Fraction]]

    init(_ score: Score, staves: some Sequence<StaffAddress>) {
        self.score = score
        var durations: [StaffAddress: [Fraction]] = [:]
        for staff in staves where durations[staff] == nil {
            durations[staff] = score[staff]?.measures.effectiveMeasureDurations()
        }
        self.durations = durations
    }

    /// The same answer as `Score.effectiveMeasureDuration(at:measureIndex:)`, 4/4 outside the staff included.
    func duration(at staff: StaffAddress, measureIndex: Int) -> Fraction {
        guard let table = durations[staff] else {
            return score.effectiveMeasureDuration(at: staff, measureIndex: measureIndex)
        }
        return table.indices.contains(measureIndex) ? table[measureIndex] : Fraction(numerator: 4, denominator: 4)
    }

    /// Whether `other` gives every staff of this table the same durations — what a planner asserts of the score its
    /// steps produced, so a step that moved a barline cannot leave the walk reading stale lengths unnoticed.
    func agrees(with other: Score) -> Bool {
        durations.allSatisfy { staff, table in other[staff]?.measures.effectiveMeasureDurations() == table }
    }
}

/// The concert key in force at each measure of the staves a walk visits — `Score.activeKey(staff:measureIndex:)` read
/// off one table per staff.
struct ActiveKeyTable {
    private let score: Score
    private let keys: [StaffAddress: [Int]]

    init(_ score: Score, staves: some Sequence<StaffAddress>) {
        self.score = score
        var keys: [StaffAddress: [Int]] = [:]
        for staff in staves where keys[staff] == nil {
            keys[staff] = score.activeKeys(staff: staff)
        }
        self.keys = keys
    }

    /// The same answer as `Score.activeKey(staff:measureIndex:)`: past the staff's last bar, the key in force there.
    func key(staff: StaffAddress, measureIndex: Int) -> Int {
        guard let table = keys[staff] else { return score.activeKey(staff: staff, measureIndex: measureIndex) }
        guard let last = table.indices.last, measureIndex >= 0 else { return 0 }
        return table[min(measureIndex, last)]
    }

    func key(at note: NoteID) -> Int {
        key(staff: note.staff, measureIndex: note.measureIndex)
    }

    /// Whether `other` puts every staff of this table in the same keys — the key-signature half of `agrees(with:)`
    /// above, for planners whose steps must not write a signature.
    func agrees(with other: Score) -> Bool {
        keys.allSatisfy { staff, table in other.activeKeys(staff: staff) == table }
    }
}
