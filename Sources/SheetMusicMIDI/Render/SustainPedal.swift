import SheetMusicCore
import SheetMusicFoundation

/// Builds the sustain-pedal (CC64) events of one part from its pedal ranges, projected through the repeat plan.
///
/// A seek or a loop wrap into a pedal relies on the engines chasing controllers; the release at tick 0 on every
/// pedalled channel guarantees a chase always finds a damper value, also before the first pedal.
enum SustainPedal {
    private static let controller = 64

    /// The CC64 events of one part: every staff's and every voice's pedal ranges, on the part's channel in force at
    /// each start. The staves of a part share its channels, so their pedals go out as ONE stream, in the part's first
    /// track: a sequencer merging two tracks keeps no order at one tick, and the lower staff's release (its opening one
    /// at tick 0, or the end of its pedal) could otherwise land after the upper staff's press on the same channel.
    /// Each staff's ranges are projected through that staff's own bar layout (a staff can carry its own meter), and the
    /// streams are merged releases-first at every tick.
    /// - Parameter layout: the bar bases and spans of a staff, in original ticks.
    static func events(
        part: Part,
        route: MidiRenderer.PartChannelRoute,
        plan: [MidiRenderer.PlaybackEntry],
        layout: (Staff) -> (bases: [Int], spans: [Int]),
        division: Int,
        tempoMap: ResolvedTempoMap,
    ) -> [TimedMidiEvent] {
        var transitions: [TimedMidiEvent] = []
        for staff in part.staves {
            let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
            let ranges = (0 ..< voiceCount).flatMap {
                PedalRanges.collect(voiceIndex: $0, staff: staff, division: division, tempoMap: tempoMap)
            }
            if ranges.isEmpty { continue }
            let staffLayout = layout(staff)
            let switches = route.routeByOriginalTick(measureBases: staffLayout.bases, division: division)
            transitions += self.transitions(
                ranges: ranges, plan: plan, measureBases: staffLayout.bases, measureSpans: staffLayout.spans,
                channel: { route.channel(atOriginalTick: $0, in: switches) },
            )
        }
        return withOpeningReleases(transitions)
    }

    /// CC64 = 127 at each range's start and 0 at its end, in unrolled ticks, on the channel in force at the start,
    /// after an opening release on every pedalled channel. At one tick every release sorts before every press.
    /// - Parameter channel: takes an ORIGINAL tick (the voice walk's `channel(atOriginalTick:)`).
    static func events(
        ranges: [PedalRange],
        plan: [MidiRenderer.PlaybackEntry],
        measureBases: [Int],
        measureSpans: [Int],
        channel: (Int) -> Int,
    ) -> [TimedMidiEvent] {
        withOpeningReleases(transitions(
            ranges: ranges, plan: plan, measureBases: measureBases, measureSpans: measureSpans, channel: channel,
        ))
    }

    /// Every release sorts ahead of every press at its tick — across streams too — and a damper value opens the
    /// track on every pedalled channel, so a chase from a seek or a loop start before the first pedal finds a released
    /// damper instead of none (and the previous pass's held one stays).
    private static func withOpeningReleases(_ transitions: [TimedMidiEvent]) -> [TimedMidiEvent] {
        var channels: [Int] = []
        for case let .controlChange(channel, _, value) in transitions.map(\.event)
            where value > 0 && !channels.contains(channel)
        {
            channels.append(channel)
        }
        let initial = channels.sorted().map { release($0, at: 0) }
        return (initial + transitions).enumerated()
            .sorted { lhs, rhs in
                (lhs.element.tick, isPress(lhs.element) ? 1 : 0, lhs.offset)
                    < (rhs.element.tick, isPress(rhs.element) ? 1 : 0, rhs.offset)
            }
            .map(\.element)
    }

    private static func isPress(_ event: TimedMidiEvent) -> Bool {
        if case let .controlChange(_, _, value) = event.event { return value > 0 }
        return false
    }

    /// The presses and releases of one staff's ranges, unsorted. A plan entry that does not follow the previous one (a
    /// jump) releases every open pedal at its first tick, and the end of the last entry releases the rest.
    private static func transitions(
        ranges: [PedalRange],
        plan: [MidiRenderer.PlaybackEntry],
        measureBases: [Int],
        measureSpans: [Int],
        channel: (Int) -> Int,
    ) -> [TimedMidiEvent] {
        var releases: [TimedMidiEvent] = []
        var presses: [TimedMidiEvent] = []
        // Ranges that are down right now, with the channel their press went to.
        var open: [(range: PedalRange, channel: Int)] = []
        let sorted = ranges.sorted { $0.startTick < $1.startTick }
        var previous: MidiRenderer.PlaybackEntry?
        for entry in plan where measureBases.indices.contains(entry.measureIndex)
            && measureSpans.indices.contains(entry.measureIndex)
        {
            if let previous, entry.measureIndex != previous.measureIndex + 1 {
                releases.append(contentsOf: open.map { release($0.channel, at: entry.tickOffset) })
                open.removeAll()
            }
            previous = entry
            let base = measureBases[entry.measureIndex]
            let end = base + measureSpans[entry.measureIndex]
            func unrolled(_ tick: Int) -> Int {
                entry.tickOffset + tick - base
            }
            for range in sorted {
                if range.startTick >= base, range.startTick < end,
                   !open.contains(where: { $0.range == range })
                {
                    let ch = channel(range.startTick)
                    presses.append(press(ch, at: unrolled(range.startTick)))
                    open.append((range, ch))
                }
                if range.endTick > base, range.endTick <= end,
                   let index = open.firstIndex(where: { $0.range == range })
                {
                    releases.append(release(open[index].channel, at: unrolled(range.endTick)))
                    open.remove(at: index)
                }
            }
        }
        if let last = plan.last, measureSpans.indices.contains(last.measureIndex) {
            let closeTick = last.tickOffset + measureSpans[last.measureIndex]
            releases.append(contentsOf: open.map { release($0.channel, at: closeTick) })
        }
        return releases + presses
    }

    private static func press(_ channel: Int, at tick: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .controlChange(channel: channel, controller: controller, value: 127))
    }

    private static func release(_ channel: Int, at tick: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .controlChange(channel: channel, controller: controller, value: 0))
    }
}
