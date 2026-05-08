import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiRendererArticulationTests {
    private let bareInstrument = Instrument(
        id: "test",
        articulations: [InstrumentArticulation(name: nil, velocity: 100, gateTime: 95)]
    )

    private func chord(_ kinds: [ChordArticulation.Kind]) -> Chord {
        Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: kinds.map { ChordArticulation(kind: $0) }
        )
    }

    @Test func noArticulationFallsBackToInstrumentDefault() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([]), instrument: bareInstrument
        )
        #expect(gate == 95) // unnamed-default preset value
    }

    @Test func staccatoUsesHardcodedFallbackWhenPresetMissing() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato]), instrument: bareInstrument
        )
        #expect(gate == 50)
    }

    @Test func staccatoUsesInstrumentPresetWhenPresent() {
        let inst = Instrument(
            id: "test",
            articulations: [
                InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
                InstrumentArticulation(name: "staccato", velocity: 100, gateTime: 25),
            ]
        )
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato]), instrument: inst
        )
        #expect(gate == 25)
    }

    @Test func staccatissimoDefaultsToThirtyThree() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccatissimo]), instrument: bareInstrument
        )
        #expect(gate == 33)
    }

    @Test func tenutoDefaultsToOneHundred() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.tenuto]), instrument: bareInstrument
        )
        #expect(gate == 100)
    }

    @Test func multipleInScopeArticulationsTakeMinimumGate() {
        // staccato (50) + tenuto (100) → 50 wins. Mirrors
        // MuseScore's MidiArticulation::aggregateOf behaviour.
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.staccato, .tenuto]), instrument: bareInstrument
        )
        #expect(gate == 50)
    }

    @Test func unknownArticulationFallsThroughToInstrumentDefault() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [.init(kind: .unknown(subtype: "articAccentAbove"))]
        )
        let gate = MidiRenderer.effectiveGateTime(
            for: chord, instrument: bareInstrument
        )
        #expect(gate == 95)
    }
}
