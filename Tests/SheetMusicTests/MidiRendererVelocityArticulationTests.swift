import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiRendererVelocityArticulationTests {
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

    @Test func combinedKindContributesStaccatoGateTime() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.accentStaccato]), instrument: bareInstrument
        )
        #expect(gate == 50)
    }

    @Test func marcatoStaccatoCombinedAlsoShortens() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.marcatoStaccato]), instrument: bareInstrument
        )
        #expect(gate == 50)
    }

    @Test func combinedAndPlainStaccatoYieldSameGateTime() {
        let combined = MidiRenderer.effectiveGateTime(
            for: chord([.accentStaccato]), instrument: bareInstrument
        )
        let plain = MidiRenderer.effectiveGateTime(
            for: chord([.accent, .staccato]), instrument: bareInstrument
        )
        #expect(combined == plain)
        #expect(combined == 50)
    }

    @Test func plainAccentDoesNotShortenGateTime() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.accent]), instrument: bareInstrument
        )
        // No duration-shaping kind in the chord → fall back to instrument default (95).
        #expect(gate == 95)
    }

    @Test func plainMarcatoDoesNotShortenGateTime() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.marcato]), instrument: bareInstrument
        )
        #expect(gate == 95)
    }
}
