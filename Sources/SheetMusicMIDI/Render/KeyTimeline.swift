import SheetMusicCore
import SheetMusicFoundation

/// The key in force along one staff, in concert pitch. A signature belongs to the staff: written in any of its voices
/// it reaches all of them, from where it stands until the next one.
struct KeyTimeline: Equatable {
    private struct Change: Equatable {
        var tickInMeasure: Int
        var key: Int
    }

    /// Per bar: the key carried into it, then its own changes in order.
    private let carried: [Int]
    private let changes: [[Change]]

    init(staff: Staff, division: Int) {
        let durations = staff.measures.effectiveMeasureDurations()
        var key = 0
        var carried: [Int] = []
        var changes: [[Change]] = []
        for (index, measure) in staff.measures.enumerated() {
            let duration = durations.indices.contains(index)
                ? durations[index] : Fraction(numerator: 4, denominator: 4)
            var own: [Change] = []
            for voice in measure.voices {
                var tick = 0
                for element in voice.elements {
                    if case let .keySignature(signature) = element {
                        own.append(Change(tickInMeasure: tick, key: signature.concertKey))
                    }
                    tick += element.cursorAdvance(division: division, in: duration)
                }
            }
            // Two voices stating one tick keep their order: the later voice's is the one in force.
            let ordered = own.enumerated()
                .sorted { ($0.element.tickInMeasure, $0.offset) < ($1.element.tickInMeasure, $1.offset) }
                .map(\.element)
            carried.append(key)
            changes.append(ordered)
            key = ordered.last?.key ?? key
        }
        self.carried = carried
        self.changes = changes
    }

    /// The key at `tickInMeasure` of the bar, a signature standing on that tick included.
    func key(atMeasure index: Int, tickInMeasure: Int = 0) -> Int {
        guard carried.indices.contains(index) else { return 0 }
        return changes[index].last { $0.tickInMeasure <= tickInMeasure }?.key ?? carried[index]
    }
}
