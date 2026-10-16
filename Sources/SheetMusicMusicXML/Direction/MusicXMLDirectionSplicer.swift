import SheetMusicCore
import SheetMusicFoundation

/// Puts direction elements into a voice at their ticks, with the `.locationShift` jogs MuseScore's writer emits for an
/// element that does not sit on a chord's start (`rw/write/twrite.cpp:3527-3593`).
enum MusicXMLDirectionSplicer {
    /// Splices `queued` into `elements`. An element at tick `T` goes just before the first chord whose `start ≥ T`
    /// (annotations precede the chord of their segment, `twrite.cpp:3527-3628`) — after any untimed element already
    /// there — or after the last chord when none starts that late. The jog is measured from that chord's recorded
    /// `start` (or the last chord's `end`), not from a running sum, so a `<forward>` gap the voice does not hold cannot
    /// misplace it; the restore after the group is `+(start − T)`. Elements are ordered by tick, ties by queue order.
    static func splice(
        _ queued: [MusicXMLQueuedElement], into elements: [VoiceElement], anchors: [MusicXMLChordAnchor],
    ) -> [VoiceElement] {
        guard !queued.isEmpty else { return elements }
        let ordered = queued.enumerated()
            .sorted { lhs, rhs in
                lhs.element.tick.precedes(rhs.element.tick)
                    || (lhs.element.tick == rhs.element.tick && lhs.offset < rhs.offset)
            }
            .map(\.element)
        var groups: [Int: [MusicXMLQueuedElement]] = [:]
        for item in ordered {
            groups[insertionPoint(for: item.tick, in: anchors), default: []].append(item)
        }
        var result: [VoiceElement] = []
        var copied = 0
        for point in groups.keys.sorted() {
            let before = point < anchors.count
            let target = before ? anchors[point].elementIndex : elements.count
            let upTo = max(copied, min(target, elements.count))
            result += elements[copied ..< upTo]
            copied = upTo
            let reference = before ? anchors[point].start : (anchors.last?.end ?? .zeroTick)
            result += jogged(groups[point] ?? [], from: reference, restoring: before)
        }
        result += elements[copied...]
        return result
    }

    /// Index into `anchors` of the first chord starting at or after `tick`; `anchors.count` when none does.
    private static func insertionPoint(for tick: Fraction, in anchors: [MusicXMLChordAnchor]) -> Int {
        anchors.firstIndex { !$0.start.precedes(tick) } ?? anchors.count
    }

    private static func jogged(
        _ group: [MusicXMLQueuedElement], from reference: Fraction, restoring: Bool,
    ) -> [VoiceElement] {
        var output: [VoiceElement] = []
        var offset = Fraction.zeroTick
        for item in group {
            let target = item.tick - reference
            if target != offset {
                output.append(.locationShift(delta: target - offset))
                offset = target
            }
            output.append(item.element)
        }
        if restoring, !offset.isZeroTick {
            output.append(.locationShift(delta: Fraction.zeroTick - offset))
        }
        return output
    }
}

extension MusicXMLDirectionSplicer {
    private struct Key: Hashable {
        let staff: Int
        let measure: Int
    }

    /// Splices every queued voice element of `events` into positional voice 0 of its staff's measure.
    /// `anchors[staff][measure]` are that voice's chord anchors; out-of-range staves / measures are dropped.
    static func apply(
        _ events: [MusicXMLDirectionEvent], anchors: [[[MusicXMLChordAnchor]]], to measures: inout [[Measure]],
    ) {
        var queues: [Key: [MusicXMLQueuedElement]] = [:]
        for event in events {
            guard case let .voice(element) = event.payload else { continue }
            queues[Key(staff: event.staff, measure: event.measure), default: []]
                .append(MusicXMLQueuedElement(tick: event.tick, element: element))
        }
        for (key, queue) in queues {
            guard measures.indices.contains(key.staff), measures[key.staff].indices.contains(key.measure),
                  !measures[key.staff][key.measure].voices.isEmpty
            else { continue }
            let hasAnchors = anchors.indices.contains(key.staff) && anchors[key.staff].indices.contains(key.measure)
            let voiceAnchors = hasAnchors ? anchors[key.staff][key.measure] : []
            var measure = measures[key.staff][key.measure]
            let spliced = splice(queue, into: measure.voices[0].elements.values, anchors: voiceAnchors)
            measure.voices[0] = Voice(elements: spliced, tuplets: measure.voices[0].tuplets)
            measures[key.staff][key.measure] = measure
        }
    }
}
