import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiRendererArticulationTests {
    private let bareInstrument = Instrument(
        id: "test",
        articulations: [InstrumentArticulation(name: nil, velocity: 100, gateTime: 95)],
    )

    private func chord(_ kinds: [ChordArticulation.Kind]) -> Chord {
        Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: kinds.map { ChordArticulation(kind: $0) },
        )
    }

    @Test func noArticulationFallsBackToInstrumentDefault() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([]), instrument: bareInstrument,
        )
        #expect(gate == 95) // unnamed-default preset value
    }

    @Test func staccatoUsesHardcodedFallbackWhenPresetMissing() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato]), instrument: bareInstrument,
        )
        #expect(gate == 50)
    }

    @Test func staccatoUsesInstrumentPresetWhenPresent() {
        let inst = Instrument(
            id: "test",
            articulations: [
                InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
                InstrumentArticulation(name: "staccato", velocity: 100, gateTime: 25),
            ],
        )
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato]), instrument: inst,
        )
        #expect(gate == 25)
    }

    @Test func staccatissimoDefaultsToThirtyThree() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccatissimo]), instrument: bareInstrument,
        )
        #expect(gate == 33)
    }

    @Test func tenutoDefaultsToOneHundred() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.tenuto]), instrument: bareInstrument,
        )
        #expect(gate == 100)
    }

    @Test func multipleInScopeArticulationsTakeMinimumGate() {
        // staccato (50) + tenuto (100) → 50 wins. Mirrors
        // MuseScore's MidiArticulation::aggregateOf behaviour.
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato, .tenuto]), instrument: bareInstrument,
        )
        #expect(gate == 50)
    }

    @Test func unknownArticulationFallsThroughToInstrumentDefault() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [.init(kind: .unknown(subtype: "articAccentAbove"))],
        )
        let gate = MidiRenderer.effectiveGateTime(
            for: chord, instrument: bareInstrument,
        )
        #expect(gate == 95)
    }

    private func renderSingleChord(
        _ chord: Chord,
        division: Int = 480,
        instrument: Instrument = Instrument(id: "test"),
    ) throws -> [TimedMidiEvent] {
        let voice = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        let score = Score(division: division, parts: [part])
        let file = try MidiRenderer.render(score: score)
        return try #require(file.tracks.first).events
    }

    /// Recover the gated note length (ticks the note actually sounded)
    /// from a rendered event stream. The renderer emits a noteOff at
    /// `noteOnTick + gatedTicks - 1`, so we add 1 back.
    private func gateTicks(from events: [TimedMidiEvent]) -> Int {
        guard let on = events.first(where: {
            if case let .noteOn(_, _, v) = $0.event { return v > 0 }
            return false
        }) else { return -1 }
        guard let off = events.first(where: {
            if case .noteOff = $0.event { return true }
            if case let .noteOn(_, _, v) = $0.event { return v == 0 }
            return false
        }) else { return -1 }
        return off.tick - on.tick + 1
    }

    @Test func endToEndStaccatoShortensToFiftyPercent() throws {
        let events = try renderSingleChord(chord([.staccato]))
        // 480 ticks * 50% = 240 ticks gated.
        #expect(gateTicks(from: events) == 240)
    }

    @Test func endToEndTenutoKeepsFullDuration() throws {
        let events = try renderSingleChord(chord([.tenuto]))
        #expect(gateTicks(from: events) == 480)
    }

    @Test func endToEndStaccatissimoShortensToThirtyThreePercent() throws {
        let events = try renderSingleChord(chord([.staccatissimo]))
        // 480 * 33% = 158 (integer truncation).
        #expect(gateTicks(from: events) == 158)
    }

    @Test func endToEndNoArticulationUsesInstrumentDefault() throws {
        // Default Instrument has no articulations table → falls through
        // to fallback 100% in defaultArticulationGateTime.
        let events = try renderSingleChord(chord([]))
        #expect(gateTicks(from: events) == 480)
    }
}
