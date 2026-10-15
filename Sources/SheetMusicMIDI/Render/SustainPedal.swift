import SheetMusicCore
import SheetMusicFoundation

/// Builds the sustain-pedal (CC64) events of one track from its pedal ranges, projected through the repeat plan.
///
/// A seek or a loop wrap into a pedal relies on the engines chasing controllers; the release at tick 0 on every
/// pedalled channel guarantees a chase always finds a damper value, also before the first pedal.
enum SustainPedal {
    private static let controller = 64

    /// The CC64 events of one staff: every voice's pedal ranges, on the part's channel in force at each start.
    static func events(
        staff: Staff,
        route: MidiRenderer.PartChannelRoute,
        plan: [MidiRenderer.PlaybackEntry],
        layout: (bases: [Int], spans: [Int]),
        division: Int,
        tempoMap: ResolvedTempoMap,
    ) -> [TimedMidiEvent] {
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        let ranges = (0 ..< voiceCount).flatMap {
            PedalRanges.collect(voiceIndex: $0, staff: staff, division: division, tempoMap: tempoMap)
        }
        if ranges.isEmpty { return [] }
        let switches = route.routeByOriginalTick(measureBases: layout.bases, division: division)
        return events(
            ranges: ranges, plan: plan, measureBases: layout.bases, measureSpans: layout.spans,
            channel: { route.channel(atOriginalTick: $0, in: switches) },
        )
    }

    /// CC64 = 127 at each range's start and 0 at its end, in unrolled ticks, on the channel in force at the start.
    /// At one tick every release sorts before every press; a plan entry that does not follow the previous one (a
    /// jump) releases every open pedal at its first tick, and the end of the last entry releases the rest.
    /// - Parameter channel: takes an ORIGINAL tick (the voice walk's `channel(atOriginalTick:)`).
    static func events(
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
        // A damper value at the start of the track on every pedalled channel, so a chase from a seek or a loop start
        // before the first pedal finds a released damper instead of none (and the previous pass's held one stays).
        var channels: [Int] = []
        for case let .controlChange(channel, _, _) in presses.map(\.event) where !channels.contains(channel) {
            channels.append(channel)
        }
        let initial = channels.sorted().map { release($0, at: 0) }
        // Releases first, so a stable sort by tick puts every off ahead of an on at the same tick.
        return (initial + releases + presses).enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)
    }

    private static func press(_ channel: Int, at tick: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .controlChange(channel: channel, controller: controller, value: 127))
    }

    private static func release(_ channel: Int, at tick: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .controlChange(channel: channel, controller: controller, value: 0))
    }
}
