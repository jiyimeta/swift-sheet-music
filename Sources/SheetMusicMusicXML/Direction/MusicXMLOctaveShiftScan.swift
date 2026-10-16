import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// The octave shift in force on each staff of a part (`MusicXmlOctaveShiftList`, `musicxmlpart.cpp:65-117`): the
/// written pitch of a note is its sounding pitch plus `12 × shift`. Entries on one staff and tick add up; a lookup is
/// the running sum over every entry at or before the tick.
struct MusicXMLOctaveShiftTable: Sendable, Equatable {
    /// A tick and the running sum of the shifts up to and including it.
    struct Entry: Sendable, Equatable {
        let tick: Fraction
        let shift: Int
    }

    /// Per staff, the entries sorted by tick.
    private var cumulative: [Int: [Entry]] = [:]

    init() {}

    /// Builds the table from `deltas[staff][tick]` (`calcOctaveShiftShifts`, `musicxmlpart.cpp:96-114`).
    init(deltas: [Int: [Fraction: Int]]) {
        for (staff, entries) in deltas {
            var sum = 0
            cumulative[staff] = entries.sorted { $0.key.precedes($1.key) }.map { entry in
                sum += entry.value
                return Entry(tick: entry.key, shift: sum)
            }
        }
    }

    /// The shift, in octaves, on `staff` (0-based) at the part-absolute `atTick`: the sum at the last entry at or
    /// before it, 0 before the first (`octaveShift`, `musicxmlpart.cpp:65-76`).
    func shift(staff: Int, atTick: Fraction) -> Int {
        var result = 0
        for entry in cumulative[staff] ?? [] {
            if atTick.precedes(entry.tick) { break }
            result = entry.shift
        }
        return result
    }
}

/// MuseScore's pass 1 over a part for its octave shifts (`MusicXmlParserPass1::direction`, `P1:3169-3230`), on the
/// same clock as the walk: each `<octave-shift>` at its direction's part-absolute time, WITHOUT `<offset>`
/// (`P1:2814`). A start and its stop pair by `number`, the stops of a direction first; a stop before its start waits
/// for it; a second start (or stop) while one waits drops both (`P1:3205-3208`, `3222-3225`). A complete pair adds
/// `+shift` at the start's time and `−shift` at the stop's, both on the staff of the direction that completed it
/// (`P1:3203-3204`, `3220-3221`). `measureStarts` is each measure's part-absolute start.
enum MusicXMLOctaveShiftScan {
    /// One `<octave-shift>` of a direction (`MusicXmlOctaveShiftDesc`).
    private struct Shift {
        let isStart: Bool
        /// Octaves, signed: `up` positive (an 8vb's notes are written higher), `down` negative.
        let size: Int
        let number: Int
        let time: Fraction
    }

    private struct Walk {
        let staffCount: Int
        var waiting: [Int: Shift] = [:]
        var deltas: [Int: [Fraction: Int]] = [:]

        /// `MusicXmlParserPass1::direction`'s pairing: the stops, then the starts.
        mutating func direction(_ node: XMLTreeNode, at time: Fraction) {
            let shifts = node.all("direction-type").flatMap { $0.all("octave-shift") }
                .compactMap { MusicXMLOctaveShiftScan.shift($0, at: time) }
            guard !shifts.isEmpty else { return }
            let staff = staffIndex(node)
            for shift in shifts where !shift.isStart {
                pair(shift, staff: staff)
            }
            for shift in shifts where shift.isStart {
                pair(shift, staff: staff)
            }
        }

        private mutating func pair(_ shift: Shift, staff: Int) {
            guard let previous = waiting.removeValue(forKey: shift.number) else {
                waiting[shift.number] = shift
                return
            }
            guard previous.isStart != shift.isStart else { return }
            let start = shift.isStart ? shift : previous
            let stop = shift.isStart ? previous : shift
            deltas[staff, default: [:]][start.time, default: 0] += start.size
            deltas[staff, default: [:]][stop.time, default: 0] -= start.size
        }

        /// `<staff>` as a 0-based index; 0 when absent or outside the part (`P1:3181-3190`).
        private func staffIndex(_ node: XMLTreeNode) -> Int {
            guard let text = node.first("staff")?.text else { return 0 }
            let index = (Int(text) ?? 0) - 1
            return (0 ..< staffCount).contains(index) ? index : 0
        }
    }

    static func scan(partNode: XMLTreeNode) -> (table: MusicXMLOctaveShiftTable, measureStarts: [Fraction]) {
        var walk = Walk(staffCount: MusicXMLMeasureWalker.detectStaffCount(partNode: partNode))
        var divisions = DivisionsContext(perQuarter: 1)
        var timeSignature: Fraction?
        var measureStart = Fraction.zeroTick
        var measureStarts: [Fraction] = []
        for measure in partNode.all("measure") {
            measureStarts.append(measureStart)
            var clock = MusicXMLMeasureClock()
            for child in measure.children {
                switch child.name {
                case "attributes":
                    read(child, divisions: &divisions, timeSignature: &timeSignature)
                case "note":
                    // A `<chord/>` tone and a grace note take no time (`P1:2780-2786`).
                    let takesTime = !child.children.contains { $0.name == "chord" || $0.name == "grace" }
                    if takesTime, let duration = duration(child, divisions: divisions) {
                        clock.advance(by: duration)
                    }
                case "forward":
                    if let duration = duration(child, divisions: divisions) { clock.forward(by: duration) }
                case "backup":
                    if let duration = duration(child, divisions: divisions) {
                        clock.backup(by: duration, divisionsPerQuarter: divisions.perQuarter)
                    }
                case "direction":
                    walk.direction(child, at: measureStart + clock.now)
                default:
                    continue
                }
            }
            measureStart += length(clock, timeSignature: timeSignature)
        }
        return (MusicXMLOctaveShiftTable(deltas: walk.deltas), measureStarts)
    }

    /// The measure's length as the walk measures it (`MusicXMLMeasureWalker.measureLength`, `P1:2839-2852`).
    private static func length(_ clock: MusicXMLMeasureClock, timeSignature: Fraction?) -> Fraction {
        guard clock.furthest.isZeroTick else { return clock.furthest }
        return timeSignature ?? Fraction(numerator: 4, denominator: 4)
    }

    /// One `<octave-shift>` (`directionType` and `handleOctaveShift`, `P1:3240-3318`); `nil` for a number no slot
    /// takes or a type that is not `up`, `down` or `stop`. MuseScore reads 22 as three octaves, 15 as two and every
    /// other size as one, while pass 2 draws a line only for 8, 15 and 22 (`P2:5291`). A deliberate deviation: a start
    /// of any other size shifts nothing here, so that a shift with no line cannot make its notes sound an octave away
    /// from the pitch the file gives them; it still pairs with its stop as MuseScore's does.
    private static func shift(_ node: XMLTreeNode, at time: Fraction) -> Shift? {
        guard let number = MusicXMLSpannerSlot.number(node.attributes["number"]) else { return nil }
        let octaves = switch Int(node.attributes["size"] ?? "") ?? 0 {
        case 8: 1
        case 15: 2
        case 22: 3
        default: 0
        }
        switch node.attributes["type"] {
        case "up": return Shift(isStart: true, size: octaves, number: number, time: time)
        case "down": return Shift(isStart: true, size: -octaves, number: number, time: time)
        case "stop": return Shift(isStart: false, size: 0, number: number, time: time)
        default: return nil
        }
    }

    /// `<divisions>` and the last `<time>` (`m_timeSigDura`), which the empty-measure length falls back on.
    private static func read(_ node: XMLTreeNode, divisions: inout DivisionsContext, timeSignature: inout Fraction?) {
        if let text = node.first("divisions")?.text, let value = Int(text), value > 0 {
            divisions.perQuarter = value
        }
        if let time = node.first("time"), let beats = time.first("beats").flatMap({ Int($0.text) }),
           let beatType = time.first("beat-type").flatMap({ Int($0.text) }), beats > 0, beatType > 0
        {
            timeSignature = Fraction(numerator: beats, denominator: beatType)
        }
    }

    /// A positive `<duration>` as a fraction of a whole note.
    private static func duration(_ node: XMLTreeNode, divisions: DivisionsContext) -> Fraction? {
        guard let text = node.first("duration")?.text, let value = Int(text), value > 0, divisions.perQuarter > 0
        else { return nil }
        return divisions.fractionOfWhole(value)
    }
}
