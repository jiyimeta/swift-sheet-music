import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// End-to-end coverage for a part whose instruments span two declared
/// `<midiPort>` values.
///
/// The rest of the instrument-change suite is single-port, which makes
/// the ORDER of the tick-0 header blocks and the port in force for the
/// note events unobservable. Both matter: `MidiChannelKey`'s contract is
/// that the port meta is positional inside a track, so a header or a
/// note sitting under the wrong `portChange` remaps onto the wrong live
/// mixer strip.
@Suite("InstrumentChange multi-port")
struct InstrumentChangeMultiPortTests {
    /// One part, two bars, a whole note in each. The tick-0 piano is on
    /// port 0 channel 0; the change in bar 2 is to an accordion on
    /// port 1 channel 0 — the same wire channel number on a different
    /// port, which is exactly how MuseScore spills past 16 channels.
    private static func twoPortScore() -> Score {
        let accordion = Instrument(
            id: "accordion",
            longName: "Accordion",
            channels: [InstrumentChannel(
                program: 21, midiChannel: 0, midiPort: 1,
            )],
        )
        let piano = Instrument(
            id: "piano",
            longName: "Piano",
            channels: [InstrumentChannel(
                program: 0, midiChannel: 0, midiPort: 0,
            )],
        )
        func bar(_ pitch: Int, _ tpc: Int) -> Measure {
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [Note(pitch: pitch, tpc: tpc)])),
            ])])
        }
        return Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: piano,
                staves: [Staff(measures: [bar(60, 14), bar(64, 18)])],
            )],
            systemMeasures: [
                SystemMeasure(),
                SystemMeasure(elements: [PositionedSystemElement(
                    position: .start,
                    element: .instrumentChange(
                        InstrumentChange(text: "to Accordion", instrument: accordion),
                    ),
                    originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                )]),
            ],
        )
    }

    /// Replay a track's positional `portChange` metas, pairing every
    /// channel-bearing event with the port in force at that point.
    private static func withPort(
        _ track: MidiTrack,
    ) -> [(tick: Int, port: Int, event: MidiEvent)] {
        var port = 0
        var out: [(tick: Int, port: Int, event: MidiEvent)] = []
        for event in track.events {
            if case let .meta(.portChange(newPort)) = event.event {
                port = newPort
                continue
            }
            out.append((event.tick, port, event.event))
        }
        return out
    }

    @Test("each tick-0 program sits under its own instrument's port")
    func headersSitUnderTheirOwnPort() throws {
        let midi = try MidiRenderer.render(score: Self.twoPortScore())
        let programs = Self.withPort(midi.tracks[0]).compactMap { entry -> (port: Int, channel: Int, program: Int)? in
            guard entry.tick == 0,
                  case let .programChange(channel, program) = entry.event
            else { return nil }
            return (entry.port, channel, program)
        }
        // Piano: program 0 on port 0. Accordion: program 21 on port 1.
        #expect(programs.contains { $0 == (0, 0, 0) })
        #expect(programs.contains { $0 == (1, 0, 21) })
    }

    @Test("notes before the change stay under the tick-0 port")
    func notesSitUnderTheirOwnPort() throws {
        let midi = try MidiRenderer.render(score: Self.twoPortScore())
        let noteOns = Self.withPort(midi.tracks[0]).compactMap { entry -> (tick: Int, port: Int, pitch: Int)? in
            guard case let .noteOn(_, pitch, velocity) = entry.event,
                  velocity > 0 else { return nil }
            return (entry.tick, entry.port, pitch)
        }
        #expect(noteOns.count == 2)
        #expect(noteOns.first { $0.pitch == 60 }?.port == 0)
        #expect(noteOns.first { $0.pitch == 64 }?.port == 1)
    }

    @Test("after the live remap each bar plays on its own mixer strip")
    func liveRemapKeepsBothStrips() throws {
        let score = Self.twoPortScore()
        var midi = try MidiRenderer.render(score: score)
        let plan = LiveChannelPlan.build(score: score)
        MidiChannelRemap.apply(midi: &midi, plan: plan)

        let ordinal0 = try #require(plan.strip(partIndex: 0, ordinal: 0))
        let ordinal1 = try #require(plan.strip(partIndex: 0, ordinal: 1))
        #expect(ordinal0.liveChannel != ordinal1.liveChannel)

        let noteOns = midi.tracks[0].events.compactMap { event -> (pitch: Int, channel: Int)? in
            guard case let .noteOn(channel, pitch, velocity) = event.event,
                  velocity > 0 else { return nil }
            return (pitch, channel)
        }
        #expect(noteOns.contains { $0 == (60, ordinal0.liveChannel) })
        #expect(noteOns.contains { $0 == (64, ordinal1.liveChannel) })

        // The tick-0 programs must land on the same strips.
        let programs = midi.tracks[0].events.compactMap { event -> (channel: Int, program: Int)? in
            guard case let .programChange(channel, program) = event.event
            else { return nil }
            return (channel, program)
        }
        #expect(programs.contains { $0 == (ordinal0.liveChannel, 0) })
        #expect(programs.contains { $0 == (ordinal1.liveChannel, 21) })
    }

    @Test("note-offs release on the channel their note-on sounded on")
    func noteOffsFollowTheirNoteOns() throws {
        // A whole note tied across the bar line into the change: the
        // tie sounds entirely on the OLD instrument's rendered channel,
        // but its release lands at a tick where the NEW instrument's
        // port is in force. Without pairing, the release would remap
        // onto the accordion strip and leave a stuck note on the piano.
        let accordion = Instrument(
            id: "accordion",
            longName: "Accordion",
            channels: [InstrumentChannel(program: 21, midiChannel: 0, midiPort: 1)],
        )
        let piano = Instrument(
            id: "piano",
            longName: "Piano",
            channels: [InstrumentChannel(program: 0, midiChannel: 0, midiPort: 0)],
        )
        let head = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14, tieForward: 1)])),
        ])])
        let tail = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieBack: 1)])),
        ])])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1", instrument: piano,
                staves: [Staff(measures: [head, tail])],
            )],
            systemMeasures: [
                SystemMeasure(),
                SystemMeasure(elements: [PositionedSystemElement(
                    position: .start,
                    element: .instrumentChange(
                        InstrumentChange(text: "to Accordion", instrument: accordion),
                    ),
                    originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                )]),
            ],
        )
        var midi = try MidiRenderer.render(score: score)
        let plan = LiveChannelPlan.build(score: score)
        MidiChannelRemap.apply(midi: &midi, plan: plan)
        let ordinal0 = try #require(plan.strip(partIndex: 0, ordinal: 0))
        let on = midi.tracks[0].events.compactMap { event -> Int? in
            guard case let .noteOn(channel, pitch, velocity) = event.event,
                  pitch == 60, velocity > 0 else { return nil }
            return channel
        }
        let off = midi.tracks[0].events.compactMap { event -> Int? in
            guard case let .noteOff(channel, pitch, _) = event.event, pitch == 60
            else { return nil }
            return channel
        }
        #expect(on == [ordinal0.liveChannel])
        #expect(off == [ordinal0.liveChannel])
    }
}
