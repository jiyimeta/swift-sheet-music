import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite("LiveChannelPlan")
struct LiveChannelPlanTests {
    private func score(
        partInstruments: [(Instrument, [Instrument])],
    ) -> Score {
        let bar = Measure(voices: [Voice(elements: [])])
        var parts: [Part] = []
        var measureCount = 1
        for (index, entry) in partInstruments.enumerated() {
            measureCount = max(measureCount, entry.1.count + 1)
            parts.append(Part(
                id: "P\(index)",
                instrument: entry.0,
                staves: [Staff(measures: Array(repeating: bar, count: entry.1.count + 1))],
            ))
        }
        var systemMeasures = Array(
            repeating: SystemMeasure(), count: measureCount,
        )
        for (partIndex, entry) in partInstruments.enumerated() {
            for (offset, instrument) in entry.1.enumerated() {
                systemMeasures[offset + 1].elements.append(
                    PositionedSystemElement(
                        position: MeasurePosition(
                            offset: Fraction(numerator: 0, denominator: 1),
                        ),
                        element: .instrumentChange(InstrumentChange(
                            text: "change", instrument: instrument,
                        )),
                        originalStaff: StaffAddress(
                            partIndex: partIndex, staffIndexInPart: 0,
                        ),
                    ),
                )
            }
        }
        return Score(division: 480, parts: parts, systemMeasures: systemMeasures)
    }

    private func instrument(
        _ id: String, program: Int, volume: Int = 100, channel: Int? = nil,
        port: Int? = nil,
    ) -> Instrument {
        Instrument(id: id, longName: id, channels: [InstrumentChannel(
            program: program, volume: volume,
            midiChannel: channel, midiPort: port,
        )])
    }

    @Test("value-equal instruments in one part share a live channel")
    func valueEqualCollapse() {
        let piano = instrument("piano", program: 0, channel: 0)
        // Same InstrumentChannel VALUES, different declared channel:
        // MuseScore allocated a fresh channel per change instance.
        let pianoAgain = instrument("piano", program: 0, channel: 6)
        let accordion = instrument("accordion", program: 21, channel: 5)
        let plan = LiveChannelPlan.build(score: score(
            partInstruments: [(piano, [accordion, pianoAgain])],
        ))
        // Dedup keys on the whole InstrumentChannel value, so the two
        // pianos differ only by declared channel and collapse.
        #expect(plan.strips.count == 2)
        #expect(plan.strips.map(\.ordinal) == [0, 1])
        #expect(
            plan.remap[MidiChannelKey(port: 0, channel: 6)]
                == plan.remap[MidiChannelKey(port: 0, channel: 0)],
        )
    }

    @Test("instruments differing only in volume keep separate channels")
    func volumeDifferenceKeepsChannel() {
        let loud = instrument("piano", program: 0, volume: 100, channel: 0)
        let soft = instrument("piano", program: 0, volume: 60, channel: 6)
        let plan = LiveChannelPlan.build(score: score(
            partInstruments: [(loud, [soft])],
        ))
        #expect(plan.strips.count == 2)
        #expect(plan.strips[0].liveChannel != plan.strips[1].liveChannel)
    }

    @Test("dedup never crosses parts")
    func dedupIsWithinPart() {
        let piano = instrument("piano", program: 0, channel: 0)
        let samePiano = instrument("piano", program: 0, channel: 1)
        let plan = LiveChannelPlan.build(score: score(
            partInstruments: [(piano, []), (samePiano, [])],
        ))
        // Two identical instruments in two DIFFERENT parts must keep
        // independent strips, or per-part mixer independence is lost.
        #expect(plan.strips.count == 2)
        #expect(plan.strips[0].liveChannel != plan.strips[1].liveChannel)
    }

    @Test("a cross-port collision is resolved onto distinct live channels")
    func crossPortCollision() {
        // Port 0 channel 0 and port 1 channel 0 are different
        // destinations in the rendered SMF; both must survive the
        // collapse onto one synth.
        let a = instrument("piano", program: 0, channel: 0, port: 0)
        let b = instrument("accordion", program: 21, channel: 0, port: 1)
        let plan = LiveChannelPlan.build(score: score(
            partInstruments: [(a, [b])],
        ))
        let live0 = plan.remap[MidiChannelKey(port: 0, channel: 0)]
        let live1 = plan.remap[MidiChannelKey(port: 1, channel: 0)]
        #expect(live0 != nil)
        #expect(live1 != nil)
        #expect(live0 != live1)
    }

    @Test("live channels skip the GM drum channel")
    func skipsDrumChannel() {
        let instruments = (0 ..< 20).map {
            instrument("i\($0)", program: $0)
        }
        let plan = LiveChannelPlan.build(score: score(
            partInstruments: [(instruments[0], Array(instruments.dropFirst()))],
        ))
        #expect(!plan.strips.map(\.liveChannel).contains(9))
    }

    @Test("past 15 melodic instruments the assignment wrap-shares")
    func wrapShares() {
        let instruments = (0 ..< 20).map {
            instrument("i\($0)", program: $0)
        }
        let plan = LiveChannelPlan.build(score: score(
            partInstruments: [(instruments[0], Array(instruments.dropFirst()))],
        ))
        // 20 distinct instruments, 15 melodic channels: no crash, no
        // channel index past 15 — the documented graceful bound.
        #expect(plan.strips.count == 20)
        #expect(plan.strips.allSatisfy { (0 ... 15).contains($0.liveChannel) })
    }

    @Test("a drumset instrument lands on channel 9")
    func drumsetOnNine() {
        var drums = instrument("drums", program: 0)
        drums.useDrumset = true
        let plan = LiveChannelPlan.build(score: score(
            partInstruments: [(drums, [])],
        ))
        #expect(plan.strips[0].liveChannel == 9)
    }

    @Test("remap rewrites channels per the active port")
    func remapHonoursPort() {
        var midi = MidiFile(division: 480, format: 1, tracks: [MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.portChange(port: 0))),
            TimedMidiEvent(tick: 0, event: .programChange(channel: 3, program: 0)),
            TimedMidiEvent(tick: 0, event: .meta(.portChange(port: 1))),
            TimedMidiEvent(tick: 10, event: .noteOn(channel: 3, pitch: 60, velocity: 90)),
        ])])
        let plan = LiveChannelPlan(
            strips: [],
            remap: [
                MidiChannelKey(port: 0, channel: 3): 0,
                MidiChannelKey(port: 1, channel: 3): 1,
            ],
            ordinalByTimelineIndex: [],
        )
        MidiChannelRemap.apply(midi: &midi, plan: plan)
        let programs = midi.tracks[0].events.compactMap { event -> Int? in
            guard case let .programChange(channel, _) = event.event else { return nil }
            return channel
        }
        let notes = midi.tracks[0].events.compactMap { event -> Int? in
            guard case let .noteOn(channel, _, _) = event.event else { return nil }
            return channel
        }
        #expect(programs == [0])
        #expect(notes == [1])
    }

    @Test("portChange metas are dropped — a live synth has one port")
    func portChangeMetasDropped() {
        var midi = MidiFile(division: 480, format: 1, tracks: [MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.portChange(port: 1))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 90)),
        ])])
        MidiChannelRemap.apply(midi: &midi, plan: LiveChannelPlan(
            strips: [], remap: [:], ordinalByTimelineIndex: [],
        ))
        #expect(!midi.tracks[0].events.contains { event in
            if case .meta(.portChange) = event.event { return true }
            return false
        })
    }

    @Test("an unmapped channel passes through unchanged")
    func unmappedPassesThrough() {
        var midi = MidiFile(division: 480, format: 1, tracks: [MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 7, pitch: 60, velocity: 90)),
        ])])
        MidiChannelRemap.apply(midi: &midi, plan: LiveChannelPlan(
            strips: [], remap: [:], ordinalByTimelineIndex: [],
        ))
        guard case let .noteOn(channel, _, _) = midi.tracks[0].events[0].event else {
            Issue.record("expected noteOn")
            return
        }
        #expect(channel == 7)
    }
}
