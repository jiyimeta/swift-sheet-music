@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct HairpinRendererIntegrationTests {
    private func makeStaffWithCresc() -> Staff {
        let mp = Dynamic(subtype: "mp", velocity: 64)
        let f = Dynamic(subtype: "f", velocity: 96)
        let q: VoiceElement = .chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        ))
        let cresc = Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: 1,
            hairpin: .init(subtype: .crescendo),
        )
        return Staff(measures: [
            Measure(voices: [Voice(elements: [
                .dynamic(mp), .spanner(cresc),
                q, q, q, q,
            ])]),
            Measure(voices: [Voice(elements: [
                .dynamic(f),
                q, q, q, q,
            ])]),
        ])
    }

    @Test func noteVelocitiesRampLinearly() throws {
        let staff = makeStaffWithCresc()
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano", articulations: []),
            staves: [staff],
        )
        let (events, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: staff, part: part,
            channel: 0, division: 480,
        )
        let velocities: [Int] = events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
        // 4 onsets in measure 1 ramp from 64 toward 96; chord at the
        // hairpin end (start of measure 2) is set by the bracket
        // Dynamic to 96 and is therefore exactly 96.
        #expect(velocities.first == 64)
        #expect(velocities[4] == 96)
        // Strictly monotonic across the ramp, no flat plateau.
        for i in 0 ..< 4 {
            #expect(velocities[i] < velocities[i + 1])
        }
    }
}
