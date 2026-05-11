import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiRendererVelocityArticulationTests {
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

    @Test func combinedKindContributesStaccatoGateTime() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.accentStaccato]), instrument: bareInstrument,
        )
        #expect(gate == 50)
    }

    @Test func marcatoStaccatoCombinedAlsoShortens() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.marcatoStaccato]), instrument: bareInstrument,
        )
        #expect(gate == 50)
    }

    @Test func combinedAndPlainStaccatoYieldSameGateTime() {
        let combined = MidiRenderer.effectiveGateTime(
            for: chord([.accentStaccato]), instrument: bareInstrument,
        )
        let plain = MidiRenderer.effectiveGateTime(
            for: chord([.accent, .staccato]), instrument: bareInstrument,
        )
        #expect(combined == plain)
        #expect(combined == 50)
    }

    @Test func plainAccentDoesNotShortenGateTime() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.accent]), instrument: bareInstrument,
        )
        // No duration-shaping kind in the chord → fall back to instrument default (95).
        #expect(gate == 95)
    }

    @Test func plainMarcatoDoesNotShortenGateTime() {
        let gate = MidiRenderer.effectiveGateTime(
            for: chord([.marcato]), instrument: bareInstrument,
        )
        #expect(gate == 95)
    }

    @Test func noVelocityArticulationFallsBackToInstrumentDefault() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([]), instrument: bareInstrument,
        )
        #expect(scale == 100) // unnamed-default preset value
    }

    @Test func accentUsesHardcodedFallbackWhenPresetMissing() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent]), instrument: bareInstrument,
        )
        #expect(scale == 120)
    }

    @Test func accentUsesInstrumentPresetWhenPresent() {
        let inst = Instrument(
            id: "test",
            articulations: [
                InstrumentArticulation(name: nil, velocity: 100, gateTime: 95),
                InstrumentArticulation(name: "accent", velocity: 140, gateTime: 100),
            ],
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent]), instrument: inst,
        )
        #expect(scale == 140)
    }

    @Test func marcatoDefaultsToOneTwenty() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.marcato]), instrument: bareInstrument,
        )
        #expect(scale == 120)
    }

    @Test func combinedKindsUseAccentOrMarcatoPreset() {
        let scale1 = MidiRenderer.effectiveVelocityScale(
            for: chord([.accentStaccato]), instrument: bareInstrument,
        )
        let scale2 = MidiRenderer.effectiveVelocityScale(
            for: chord([.marcatoStaccato]), instrument: bareInstrument,
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
            ],
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.accent, .marcato]), instrument: inst,
        )
        #expect(scale == 130)
    }

    @Test func durationOnlyArticulationsAreIgnoredForVelocity() {
        let scale = MidiRenderer.effectiveVelocityScale(
            for: chord([.staccato, .tenuto]), instrument: bareInstrument,
        )
        // No velocity-shaping kind present → fall back to default.
        #expect(scale == 100)
    }

    @Test func unknownArticulationVelocityFallsThroughToInstrumentDefault() {
        let c = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [.init(kind: .unknown(subtype: "articSoftAccentAbove"))],
        )
        let scale = MidiRenderer.effectiveVelocityScale(
            for: c, instrument: bareInstrument,
        )
        #expect(scale == 100)
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

    private func firstNoteOnVelocity(_ events: [TimedMidiEvent]) -> Int {
        for e in events {
            if case let .noteOn(_, _, v) = e.event, v > 0 { return v }
        }
        return -1
    }

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

    @Test func endToEndAccentBoostsVelocity() throws {
        // Default running velocity = mf (80). accent scale = 120%.
        // 80 * 120 / 100 = 96.
        let events = try renderSingleChord(chord([.accent]))
        #expect(firstNoteOnVelocity(events) == 96)
    }

    @Test func endToEndMarcatoBoostsVelocity() throws {
        let events = try renderSingleChord(chord([.marcato]))
        #expect(firstNoteOnVelocity(events) == 96)
    }

    @Test func endToEndAccentStaccatoBoostsVelocityAndShortens() throws {
        let events = try renderSingleChord(chord([.accentStaccato]))
        #expect(firstNoteOnVelocity(events) == 96)
        #expect(gateTicks(from: events) == 240) // 480 * 50%
    }

    @Test func endToEndMarcatoStaccatoBoostsVelocityAndShortens() throws {
        let events = try renderSingleChord(chord([.marcatoStaccato]))
        #expect(firstNoteOnVelocity(events) == 96)
        #expect(gateTicks(from: events) == 240)
    }

    @Test func endToEndPlainAccentDoesNotShortenGate() throws {
        let events = try renderSingleChord(chord([.accent]))
        #expect(gateTicks(from: events) == 480) // full quarter
    }

    @Test func endToEndCombinedAndSplitMatchExactly() throws {
        let combined = try renderSingleChord(chord([.accentStaccato]))
        let split = try renderSingleChord(chord([.accent, .staccato]))
        #expect(firstNoteOnVelocity(combined) == firstNoteOnVelocity(split))
        #expect(gateTicks(from: combined) == gateTicks(from: split))
    }

    @Test func endToEndNoVelocityArticulationKeepsRunningVelocity() throws {
        let events = try renderSingleChord(chord([.staccato]))
        // No velocity-shaping articulation → mf (80) untouched.
        #expect(firstNoteOnVelocity(events) == 80)
    }

    @Test func endToEndDynamicAndAccentMultiply() throws {
        // A `<Dynamic>` event sets the running velocity; then the
        // accent multiplies on top per `base * eff / def`. With base
        // = 100 (Dynamic.velocity) and eff = 120 (accent default), the
        // result is 100 * 120 / 100 = 120.
        let dynamic = Dynamic(subtype: "f", velocity: 100)
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [.init(kind: .accent)],
        )
        let voice = Voice(elements: [.dynamic(dynamic), .chord(chord)])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P1", instrument: Instrument(id: "test"), staves: [staff],
        )
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let events = try #require(file.tracks.first).events
        #expect(firstNoteOnVelocity(events) == 120)
    }

    @Test func endToEndAccentBoostsMainOnlyNotGraces() throws {
        // The main chord carries `.accent` and gets boosted; the leading
        // grace note (acciaccatura) must NOT inherit the boost — graces
        // are unarticulated satellites of the parent chord. Default mf
        // (80) for the grace, accent-boosted (96) for the main.
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
        )
        let main = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            graceNotesBefore: [grace],
            articulations: [.init(kind: .accent)],
        )
        let events = try renderSingleChord(main)
        let onVelocities = events.compactMap { e -> Int? in
            if case let .noteOn(_, _, v) = e.event, v > 0 { return v }
            return nil
        }
        #expect(onVelocities.count == 2)
        #expect(onVelocities.first == 80) // grace pitch=62, unaffected
        #expect(onVelocities.last == 96) // main pitch=60, accent-boosted
    }
}
