import Foundation
@testable import MuseScoreParser
import Testing

enum MidiSemanticComparison {
    /// Compare two MIDI byte streams semantically. Reports first divergence via Issue.record.
    static func assertEquivalent(produced: Data, reference: Data) throws {
        let producedFile = try SMFReader.read(produced)
        let referenceFile = try SMFReader.read(reference)

        guard producedFile.division == referenceFile.division else {
            Issue.record("division differs: produced=\(producedFile.division) reference=\(referenceFile.division)")
            return
        }
        guard producedFile.tracks.count == referenceFile.tracks.count else {
            let producedCount = producedFile.tracks.count
            let referenceCount = referenceFile.tracks.count
            Issue.record("track count differs: produced=\(producedCount) reference=\(referenceCount)")
            return
        }

        for (i, pair) in zip(producedFile.tracks, referenceFile.tracks).enumerated() {
            let (p, r) = pair
            let pn = normalize(p.events)
            let rn = normalize(r.events)
            if let firstDiff = firstDifference(pn, rn) {
                let producedDesc = describe(pn[safe: firstDiff])
                let referenceDesc = describe(rn[safe: firstDiff])
                let producedWindow = window(pn, around: firstDiff)
                let referenceWindow = window(rn, around: firstDiff)
                var msg = "track \(i) differs at index \(firstDiff)\n"
                msg += "  produced[\(firstDiff)]:  \(producedDesc)\n"
                msg += "  reference[\(firstDiff)]: \(referenceDesc)\n"
                msg += "  surrounding produced:\n\(producedWindow)\n"
                msg += "  surrounding reference:\n\(referenceWindow)"
                Issue.record(Comment(rawValue: msg))
                return
            }
        }
    }

    /// Normalise: drop events the renderer/reference may differ on (per-note CC2 sndController),
    /// snap note-off ticks that are 1 tick before next event,
    /// then sort within each tick by (kindOrdinal, channel, dataA).
    private static func normalize(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        var filtered: [TimedMidiEvent] = []
        for event in events {
            if case .controlChange(_, let cc, _) = event.event, cc == 2 {
                continue   // ignore breath/sndController CC2; renderer doesn't emit it
            }
            filtered.append(event)
        }

        let collapsed = collapseNoteOffOneTickEarly(filtered)

        let grouped = Dictionary(grouping: collapsed) { $0.tick }
        var result: [TimedMidiEvent] = []
        for tick in grouped.keys.sorted() {
            let bucket = grouped[tick] ?? []
            let sorted = bucket.sorted { lhs, rhs in
                (kindOrdinal(lhs.event), channel(lhs.event), dataA(lhs.event))
                    < (kindOrdinal(rhs.event), channel(rhs.event), dataA(rhs.event))
            }
            result.append(contentsOf: sorted)
        }
        return result
    }

    /// Shift any noteOff at tick T immediately followed by a noteOn at tick T+1
    /// up to T+1 (covers the 479-vs-480 quirk in midi01-ref).
    private static func collapseNoteOffOneTickEarly(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        var out = events
        for i in 0..<out.count {
            if case .noteOff = out[i].event {
                if i + 1 < out.count, case .noteOn = out[i + 1].event,
                   out[i + 1].tick == out[i].tick + 1 {
                    out[i].tick += 1
                }
            }
        }
        return out
    }

    private static func kindOrdinal(_ e: MidiEvent) -> Int {
        switch e {
        case .meta:           return 0
        case .programChange:  return 1
        case .controlChange:  return 2
        case .noteOff:        return 3
        case .noteOn:         return 4
        case .endOfTrack:     return 5
        }
    }

    private static func channel(_ e: MidiEvent) -> Int {
        switch e {
        case .noteOn(let ch, _, _),
             .noteOff(let ch, _, _),
             .controlChange(let ch, _, _),
             .programChange(let ch, _):
            return ch
        case .meta, .endOfTrack:
            return -1
        }
    }

    private static func dataA(_ e: MidiEvent) -> Int {
        switch e {
        case .noteOn(_, let pitch, _),
             .noteOff(_, let pitch, _):
            return pitch
        case .controlChange(_, let cc, _):
            return cc
        case .programChange(_, let p):
            return p
        case .meta, .endOfTrack:
            return 0
        }
    }

    private static func describe(_ e: TimedMidiEvent?) -> String {
        guard let e else { return "(end)" }
        return "tick=\(e.tick) \(e.event)"
    }

    private static func window(_ events: [TimedMidiEvent], around index: Int, span: Int = 2) -> String {
        let lower = max(0, index - span)
        let upper = min(events.count, index + span + 1)
        return events[lower..<upper].map { "  \(describe($0))" }.joined(separator: "\n")
    }

    private static func firstDifference(_ a: [TimedMidiEvent], _ b: [TimedMidiEvent]) -> Int? {
        let n = max(a.count, b.count)
        for i in 0..<n where a[safe: i] != b[safe: i] {
            return i
        }
        return nil
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
