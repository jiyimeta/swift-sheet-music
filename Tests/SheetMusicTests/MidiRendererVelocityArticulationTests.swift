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

    @Test func noVelocityArticulationFallsBackToInstrumentDefault() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([]), instrument: bareInstrument
        )
        #expect(scale == 100) // unnamed-default preset value
    }

    @Test func accentUsesHardcodedFallbackWhenPresetMissing() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent]), instrument: bareInstrument
        )
        #expect(scale == 120)
    }

    @Test func accentUsesInstrumentPresetWhenPresent() {
        let inst = Instrument(
            id: "test",
            articulations: [
                InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
                InstrumentArticulation(name: "accent", velocity: 140, gateTime: 100),
            ]
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent]), instrument: inst
        )
        #expect(scale == 140)
    }

    @Test func marcatoDefaultsToOneTwenty() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.marcato]), instrument: bareInstrument
        )
        #expect(scale == 120)
    }

    @Test func combinedKindsUseAccentOrMarcatoPreset() {
        let scale1 = MidiRenderer.effectiveVelocityScale(
            for: chord([.accentStaccato]), instrument: bareInstrument
        )
        let scale2 = MidiRenderer.effectiveVelocityScale(
            for: chord([.marcatoStaccato]), instrument: bareInstrument
        )
        #expect(scale1 == 120)
        #expect(scale2 == 120)
    }

    @Test func multipleVelocityArticulationsTakeMaximum() {
        // accent (120) + marcato (overridden to 130) → 130 wins.
        let inst = Instrument(
            id: "test",
            articulations: [
                InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
                InstrumentArticulation(name: "marcato", velocity: 130, gateTime: 100),
            ]
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent, .marcato]), instrument: inst
        )
        #expect(scale == 130)
    }

    @Test func durationOnlyArticulationsAreIgnoredForVelocity() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.staccato, .tenuto]), instrument: bareInstrument
        )
        // No velocity-shaping kind present → fall back to default.
        #expect(scale == 100)
    }

    @Test func unknownArticulationVelocityFallsThroughToInstrumentDefault() {
        let c = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [.init(kind: .unknown(subtype: "articSoftAccentAbove"))]
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: c, instrument: bareInstrument
        )
        #expect(scale == 100)
    }
}
