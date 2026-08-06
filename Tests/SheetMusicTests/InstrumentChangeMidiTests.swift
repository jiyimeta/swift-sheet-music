import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite("InstrumentChange MIDI")
struct InstrumentChangeMidiTests {
    static func fixtureScore() throws -> Score {
        let url = try #require(
            Bundle.module.url(
                forResource: "instrument-change", withExtension: "mscx",
            ),
        )
        return try MSCXParser.parse(Data(contentsOf: url))
    }

    @Test("one assignment per change instance, not per distinct instrument")
    func assignmentPerInstance() throws {
        let assignments = try MidiRenderer.assignChannels(score: Self.fixtureScore())
        #expect(assignments.count == 1)
        #expect(assignments[0].count == 2)
        #expect(assignments[0].map(\.instrumentOrdinal) == [0, 1])
        // The tick-0 piano has no <midiChannel>, so it takes channel 0.
        #expect(assignments[0][0].channel == 0)
        // The accordion declares <midiChannel>5</midiChannel>.
        #expect(assignments[0][1].channel == 5)
        #expect(assignments[0][1].flavour.program == 21)
    }

    @Test("channel identity is the (port, channel) pair")
    func portIsPartOfIdentity() {
        let a = MidiChannelKey(port: 0, channel: 3)
        let b = MidiChannelKey(port: 1, channel: 3)
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("a declared midiPort rides on the assignment, not the part")
    func declaredPortIsHonoured() {
        var accordion = Instrument(
            id: "accordion",
            channels: [InstrumentChannel(program: 21, midiChannel: 3, midiPort: 1)],
        )
        accordion.longName = "Accordion"
        let bar = Measure(voices: [Voice(elements: [])])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "piano", channels: [InstrumentChannel(midiChannel: 3)]),
                staves: [Staff(measures: [bar, bar])],
            )],
            systemMeasures: [
                SystemMeasure(),
                SystemMeasure(elements: [PositionedSystemElement(
                    position: MeasurePosition(offset: Fraction(numerator: 0, denominator: 1)),
                    element: .instrumentChange(
                        InstrumentChange(text: "to Accordion", instrument: accordion),
                    ),
                    originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                )]),
            ],
        )
        let assignments = MidiRenderer.assignChannels(score: score)
        // Same wire channel number, different port — two distinct keys.
        #expect(assignments[0][0].key == MidiChannelKey(port: 0, channel: 3))
        #expect(assignments[0][1].key == MidiChannelKey(port: 1, channel: 3))
    }

    @Test("both instruments get a full header block at tick 0")
    func headersForEveryInstrumentAtTickZero() throws {
        let midi = try MidiRenderer.render(score: Self.fixtureScore())
        let tickZeroPrograms = midi.tracks[0].events
            .filter { $0.tick == 0 }
            .compactMap { event -> (Int, Int)? in
                guard case let .programChange(channel, program) = event.event
                else { return nil }
                return (channel, program)
            }
        #expect(tickZeroPrograms.contains { $0 == (0, 0) }) // piano
        #expect(tickZeroPrograms.contains { $0 == (5, 21) }) // accordion
    }

    @Test("no program change is emitted after tick 0")
    func noMidStreamProgramChange() throws {
        let midi = try MidiRenderer.render(score: Self.fixtureScore())
        let late = midi.tracks.flatMap(\.events).filter { event in
            guard case .programChange = event.event else { return false }
            return event.tick > 0
        }
        #expect(late.isEmpty)
    }

    @Test("notes before the change carry channel 0, after it channel 5")
    func notesRouteByTick() throws {
        let midi = try MidiRenderer.render(score: Self.fixtureScore())
        let noteOns = midi.tracks.flatMap(\.events).compactMap { event -> (tick: Int, channel: Int, pitch: Int)? in
            guard case let .noteOn(channel, pitch, velocity) = event.event,
                  velocity > 0
            else { return nil }
            return (event.tick, channel, pitch)
        }.sorted { $0.tick < $1.tick }
        #expect(noteOns.count == 4)
        // Measures 0-1 (pitches 60, 62) on the piano channel.
        #expect(noteOns[0].pitch == 60 && noteOns[0].channel == 0)
        #expect(noteOns[1].pitch == 62 && noteOns[1].channel == 0)
        // Measures 2-3 (pitches 64, 65) on the accordion channel.
        #expect(noteOns[2].pitch == 64 && noteOns[2].channel == 5)
        #expect(noteOns[3].pitch == 65 && noteOns[3].channel == 5)
    }

    @Test("note-offs follow their note-ons onto the same channel")
    func noteOffsMatch() throws {
        let midi = try MidiRenderer.render(score: Self.fixtureScore())
        let offs = midi.tracks.flatMap(\.events).compactMap { event -> (pitch: Int, channel: Int)? in
            guard case let .noteOff(channel, pitch, _) = event.event
            else { return nil }
            return (pitch, channel)
        }
        #expect(offs.contains { $0 == (64, 5) })
        #expect(offs.contains { $0 == (60, 0) })
    }

    @Test("a change mid-measure switches at that position, not the bar line")
    func midMeasureChange() throws {
        // Two half notes in one bar; the change sits on beat 3.
        let half = NoteDuration.fraction(Fraction(numerator: 1, denominator: 2))
        let bar = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: half, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: half, notes: [Note(pitch: 62, tpc: 16)])),
        ])])
        let accordion = Instrument(
            id: "accordion",
            channels: [InstrumentChannel(program: 21, midiChannel: 5)],
        )
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "piano", channels: [InstrumentChannel()]),
                staves: [Staff(measures: [bar])],
            )],
            systemMeasures: [SystemMeasure(elements: [PositionedSystemElement(
                position: MeasurePosition(offset: Fraction(numerator: 1, denominator: 2)),
                element: .instrumentChange(
                    InstrumentChange(text: "to Accordion", instrument: accordion),
                ),
                originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            )])],
        )
        let midi = try MidiRenderer.render(score: score)
        let noteOns = midi.tracks.flatMap(\.events).compactMap { event -> (pitch: Int, channel: Int)? in
            guard case let .noteOn(channel, pitch, velocity) = event.event,
                  velocity > 0 else { return nil }
            return (pitch, channel)
        }
        #expect(noteOns.contains { $0 == (60, 0) })
        #expect(noteOns.contains { $0 == (62, 5) })
    }

    @Test("a tie chain spanning a change sounds entirely on the head's channel")
    func tieChainSpanningChangeStaysOnHeadChannel() throws {
        // A whole note tied into a half note; the change lands exactly
        // at the tail chord's onset — the tick-resolved channel for
        // the tail element ALONE would be the new instrument.
        let head = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14, tieForward: 1)])),
        ])])
        let tail = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14, tieBack: 1)])),
        ])])
        let accordion = Instrument(
            id: "accordion",
            channels: [InstrumentChannel(program: 21, midiChannel: 5)],
        )
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "piano", channels: [InstrumentChannel()]),
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
        let midi = try MidiRenderer.render(score: score)
        let noteOns = midi.tracks.flatMap(\.events).compactMap { event -> (tick: Int, channel: Int)? in
            guard case let .noteOn(channel, pitch, velocity) = event.event,
                  pitch == 60, velocity > 0 else { return nil }
            return (event.tick, channel)
        }
        let noteOffs = midi.tracks.flatMap(\.events).compactMap { event -> (tick: Int, channel: Int)? in
            guard case let .noteOff(channel, pitch, _) = event.event, pitch == 60
            else { return nil }
            return (event.tick, channel)
        }
        #expect(noteOns.count == 1)
        #expect(noteOffs.count == 1)
        // The pair must actually span the tied duration — a mismatched
        // note-off channel makes `resolveUnisonOverlap`'s (channel,
        // pitch)-keyed pairing silently drop the real note-off and
        // close the note-on at its own onset instead, which would
        // ALSO leave onTick == offTick == 0 and could otherwise
        // masquerade as "both on channel 0". Asserting the real tied
        // span (whole note into a half note: onset 0, release at
        // 1920 + 960 - 1) rules that degenerate case out.
        #expect(noteOns.first?.tick == 0)
        #expect(noteOffs.first?.tick == 2879)
        // Both halves of the tied pair sound on the OLD (piano) channel —
        // the one in force at the tie's head — not the new accordion
        // channel that takes over exactly at the tail's onset.
        #expect(noteOns.first?.channel == 0)
        #expect(noteOffs.first?.channel == 0)
        #expect(noteOns.first?.channel == noteOffs.first?.channel)
    }

    @Test("a score with no changes renders exactly as before")
    func noChangeScoreIsUnaffected() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
        )
        let score = try MSCXParser.parse(Data(contentsOf: url))
        let midi = try MidiRenderer.render(score: score)
        let channels = Set(midi.tracks.flatMap(\.events).compactMap { event -> Int? in
            guard case let .noteOn(channel, _, _) = event.event else { return nil }
            return channel
        })
        #expect(channels == [0])
    }
}
