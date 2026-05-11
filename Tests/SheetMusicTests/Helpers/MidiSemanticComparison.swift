import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

enum MidiSemanticComparison {
    struct Options {
        /// MuseScore's `tempomapWithPauses` restoration occasionally
        /// emits the same kind of meta event twice within ≤1 tick at
        /// section boundaries. The default normaliser already drops
        /// these; this flag is reserved for future tuning and is a
        /// no-op today (kept in the spec for API stability).
        var ignoreTempoNoise = false
        /// Drop control-change events from both produced and reference
        /// before comparing. Used for Single Note Dynamics (CC11 etc.)
        /// where the v1 implementation only does note-on velocity.
        var ignoreControlChange = false
    }

    /// Compare two MIDI byte streams semantically. Reports first divergence via Issue.record.
    static func assertEquivalent(produced: Data, reference: Data) throws {
        try assertEquivalent(produced: produced, reference: reference, options: .init())
    }

    static func assertEquivalent(
        produced: Data,
        reference: Data,
        options: Options,
    ) throws {
        let producedFile = try MidiReader.read(produced)
        let referenceFile = try MidiReader.read(reference)

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
            let pn = normalize(p.events, options: options)
            let rn = normalize(r.events, options: options)
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

    /// Normalise:
    /// - drop the per-note CC2 sndController the renderer doesn't emit,
    /// - snap noteOffs 1 tick before next noteOn (479 vs 480),
    /// - drop adjacent same-kind meta events (MuseScore's tempomap restoration
    ///   pattern emits restoration tempos at boundary-1 that get immediately
    ///   superseded at boundary; semantically a no-op),
    /// - sort within each tick by (kindOrdinal, metaKind, channel, dataA).
    private static func normalize(_ events: [TimedMidiEvent], options: Options) -> [TimedMidiEvent] {
        var filtered: [TimedMidiEvent] = []
        for event in events {
            if case let .controlChange(_, cc, _) = event.event {
                if options.ignoreControlChange { continue }
                if cc == 2 { continue }
            }
            filtered.append(event)
        }

        let snapped = collapseNoteOffOneTickEarly(filtered)
        let dedup = dropRedundantMetas(snapped)

        let grouped = Dictionary(grouping: dedup) { $0.tick }
        var result: [TimedMidiEvent] = []
        for tick in grouped.keys.sorted() {
            let bucket = grouped[tick] ?? []
            let sorted = bucket.sorted { lhs, rhs in
                let lhsKey = (kindOrdinal(lhs.event), metaKindOrdinal(lhs.event), channel(lhs.event), dataA(lhs.event))
                let rhsKey = (kindOrdinal(rhs.event), metaKindOrdinal(rhs.event), channel(rhs.event), dataA(rhs.event))
                return lhsKey < rhsKey
            }
            result.append(contentsOf: sorted)
        }
        return result
    }

    /// Drop a meta event at tick T when the same-kind meta is also present at T+1
    /// (or even at T from a different source). MuseScore's exportmidi can emit the
    /// same kind of meta twice within ≤1 tick at section boundaries; only the
    /// later one is semantically meaningful.
    private static func dropRedundantMetas(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        // Walk back-to-front: for each meta we keep, remember its kind and tick.
        // For each meta we encounter (going backwards), if a later meta of the
        // same kind exists within ≤1 tick, drop it.
        var keep = Array(repeating: true, count: events.count)
        let indexed = events.enumerated().filter {
            if case .meta = $0.element.event { true } else { false }
        }
        // Group meta indices by kind for efficient lookup.
        var byKind: [Int: [(index: Int, tick: Int)]] = [:]
        for (i, ev) in indexed {
            if case let .meta(meta) = ev.event {
                byKind[metaKindRaw(meta), default: []].append((i, ev.tick))
            }
        }
        for (kind, items) in byKind {
            let sorted = items.sorted { $0.tick < $1.tick }
            for k in 0 ..< (sorted.count - 1) {
                let curr = sorted[k]
                let next = sorted[k + 1]
                if next.tick - curr.tick <= 1 {
                    keep[curr.index] = false
                }
            }
            _ = kind
        }
        return zip(events, keep).compactMap { $1 ? $0 : nil }
    }

    private static func metaKindRaw(_ m: MetaEvent) -> Int {
        switch m {
        case .trackName: 0
        case .timeSignature: 1
        case .keySignature: 2
        case .tempo: 3
        case .portChange: 4
        case .marker: 5
        }
    }

    private static func metaKindOrdinal(_ e: MidiEvent) -> Int {
        if case let .meta(m) = e { return metaKindRaw(m) }
        return -1
    }

    /// Shift any noteOff at tick T immediately followed by a noteOn at tick T+1
    /// up to T+1 (covers the 479-vs-480 quirk in midi01-ref).
    private static func collapseNoteOffOneTickEarly(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        var out = events
        for i in 0 ..< out.count {
            if case .noteOff = out[i].event {
                if i + 1 < out.count, case .noteOn = out[i + 1].event,
                   out[i + 1].tick == out[i].tick + 1
                {
                    out[i].tick += 1
                }
            }
        }
        return out
    }

    private static func kindOrdinal(_ e: MidiEvent) -> Int {
        switch e {
        case .meta: 0
        case .programChange: 1
        case .controlChange: 2
        case .pitchBend: 3
        case .noteOff: 4
        case .noteOn: 5
        case .endOfTrack: 6
        }
    }

    private static func channel(_ e: MidiEvent) -> Int {
        switch e {
        case let .noteOn(ch, _, _),
             let .noteOff(ch, _, _),
             let .controlChange(ch, _, _),
             let .programChange(ch, _),
             let .pitchBend(ch, _):
            return ch
        case .meta, .endOfTrack:
            return -1
        }
    }

    private static func dataA(_ e: MidiEvent) -> Int {
        switch e {
        case let .noteOn(_, pitch, _),
             let .noteOff(_, pitch, _):
            return pitch
        case let .controlChange(_, cc, _):
            return cc
        case let .programChange(_, p):
            return p
        case let .pitchBend(_, value):
            return value
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
        return events[lower ..< upper].map { "  \(describe($0))" }.joined(separator: "\n")
    }

    private static func firstDifference(_ a: [TimedMidiEvent], _ b: [TimedMidiEvent]) -> Int? {
        let n = max(a.count, b.count)
        for i in 0 ..< n where a[safe: i] != b[safe: i] {
            return i
        }
        return nil
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
