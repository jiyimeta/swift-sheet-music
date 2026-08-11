@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// MuseScore's `HairpinType` has four members — `CRESC_HAIRPIN`,
/// `DIM_HAIRPIN`, `CRESC_LINE`, `DIM_LINE` (hairpin.h:32). The two
/// *line* forms print "cresc." / "dim." instead of a wedge but drive
/// playback exactly like their wedge counterparts, so the velocity
/// ramp's sign has to come from `Hairpin::isCrescendo()` semantics —
/// `CRESC_HAIRPIN || CRESC_LINE` — not from an equality test against
/// the single `.crescendo` case.
struct HairpinLinePlaybackTests {
    private func velocities(
        subtype: Spanner.HairpinPayload.Subtype,
    ) throws -> [Int] {
        let q: VoiceElement = .chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        ))
        let hairpin = Spanner(
            kind: .hairpin, rawType: "HairPin",
            nextMeasuresOffset: 1,
            hairpin: .init(subtype: subtype, veloChange: 20),
        )
        let staff = Staff(measures: [
            Measure(voices: [Voice(elements: [
                .dynamic(Dynamic(subtype: "mf", velocity: 80)),
                .spanner(hairpin),
                q, q, q, q,
            ])]),
            Measure(voices: [Voice(elements: [q, q, q, q])]),
        ])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano", articulations: []),
            staves: [staff],
        )
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0, staff: staff, part: part,
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: 480,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: 480),
        )
        return events.compactMap {
            if case let .noteOn(_, _, v) = $0.event { return v } else { return nil }
        }
    }

    @Test func crescLineRampsUp() throws {
        let v = try velocities(subtype: .crescLine)
        #expect(v[0] == 80)
        #expect(v[4] > v[0])
    }

    @Test func dimLineRampsDown() throws {
        let v = try velocities(subtype: .dimLine)
        #expect(v[0] == 80)
        #expect(v[4] < v[0])
    }
}
