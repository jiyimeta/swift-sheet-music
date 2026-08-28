import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct TremoloSegmentsTests {
    @Test func single_r16_on_quarter_yields_four_segments() throws {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let segments = try MidiRenderer.tremoloSegments(
            for: chord,
            nominalDuration: 480,
            followerChord: nil,
        )
        #expect(segments.count == 4)
        #expect(segments.allSatisfy { $0.pitches == [60] })
        #expect(segments.map(\.ticks) == [120, 120, 120, 120])
    }

    @Test func between_c8_alternates_pitch_sets() throws {
        let start = Chord(
            duration: .half,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(
            duration: .half,
            notes: [Note(pitch: 64, tpc: 18)],
        )
        let segments = try MidiRenderer.tremoloSegments(
            for: start,
            nominalDuration: 480,
            followerChord: follower,
        )
        // r8 → 2 strokes per chord × 2 chords = 4 segments total,
        // alternating start.pitches, follower.pitches, start, follower.
        // nominalDuration=480, totalDuration=960, totalStrokes=4 → 240 ticks each.
        #expect(segments.count == 4)
        #expect(segments[0].pitches == [60])
        #expect(segments[1].pitches == [64])
        #expect(segments[2].pitches == [60])
        #expect(segments[3].pitches == [64])
        #expect(segments.allSatisfy { $0.ticks == 240 })
    }

    @Test func no_tremolo_yields_single_segment() throws {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
        )
        let segments = try MidiRenderer.tremoloSegments(
            for: chord,
            nominalDuration: 480,
            followerChord: nil,
        )
        #expect(segments == [
            MidiRenderer.TremoloSegment(pitches: [60], ticks: 480),
        ])
    }
}

struct TremoloVoiceRenderTests {
    private static func makePart(staff: Staff) -> Part {
        Part(
            id: "P1",
            instrument: Instrument(id: "piano", articulations: []),
            staves: [staff],
        )
    }

    @Test func single_r16_on_quarter_emits_four_noteOns() throws {
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Self.makePart(staff: staff),
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: 480,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: 480),
        )
        let noteOns = events.filter {
            if case .noteOn = $0.event { return true }
            return false
        }
        #expect(noteOns.count == 4)
        let onTicks = noteOns.map(\.tick)
        #expect(onTicks == [0, 120, 240, 360])
    }

    @Test func between_c8_renders_alternating_pitch_quartet() throws {
        let start = Chord(
            duration: .half,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(
            duration: .half,
            notes: [Note(pitch: 64, tpc: 18)],
        )
        let measure = Measure(voices: [Voice(elements: [
            .chord(start), .chord(follower),
        ])])
        let staff = Staff(measures: [measure])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Self.makePart(staff: staff),
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: 480,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: 480),
        )
        let pitchOns = events.compactMap { e -> Int? in
            if case let .noteOn(_, p, _) = e.event { return p }
            return nil
        }
        #expect(pitchOns == [60, 64, 60, 64])
    }

    /// The engraved shape this exists for: a roll starting on a `ppp`
    /// partway through a measure, under a crescendo that lands on the
    /// `f` at the next downbeat. Every stroke between them has to climb.
    @Test func aRollFromPppToFClimbsAcrossItsStrokes() throws {
        let note = Note(pitch: 60, tpc: 14)
        let measure1 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [note])),
            .chord(Chord(duration: .quarter, notes: [note])),
            .chord(Chord(duration: .quarter, notes: [note])),
            .dynamic(Dynamic(subtype: "ppp", velocity: 16)),
            .spanner(Spanner(
                kind: .hairpin, rawType: "HairPin",
                nextMeasuresOffset: 1,
                hairpin: .init(subtype: .crescendo),
            )),
            .chord(Chord(
                duration: .quarter, notes: [note],
                tremolo: Tremolo(subtype: .r16),
            )),
        ])])
        let measure2 = Measure(voices: [Voice(elements: [
            .dynamic(Dynamic(subtype: "f", velocity: 96)),
            .chord(Chord(duration: .whole, notes: [note])),
        ])])
        let staff = Staff(measures: [measure1, measure2])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Self.makePart(staff: staff),
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: 480,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: 480),
        )
        let strokes = events
            .filter { $0.tick >= 1440 && $0.tick < 1920 }
            .compactMap { e -> Int? in
                if case let .noteOn(_, _, v) = e.event { return v }
                return nil
            }
        #expect(strokes.count == 4)
        #expect(strokes.first == 16)
        #expect(strokes.last ?? 0 > 60, "the last stroke should be approaching the f")
        for i in 1 ..< strokes.count {
            #expect(strokes[i] > strokes[i - 1], "stroke \(i) must be louder")
        }
    }

    /// A tremolo under a hairpin swells across its own strokes. Each
    /// stroke is a separate attack, so each reads the ramp at its own
    /// tick — MuseScore does this explicitly, and says why:
    ///
    ///     // Get the velocity used for this note from the staff
    ///     // This allows correct playback of tremolos even without SND enabled.
    ///     int velo = staff->velocities().val(nonUnwoundTick);
    ///
    /// (`CompatMidiRender::collectNote`, where `nonUnwoundTick` is the
    /// *NoteEvent's* onset, not the chord's.) Sampling the ramp once at
    /// the chord onset instead flattens a rolled crescendo — exactly
    /// the case a drum roll under a wedge is written for.
    @Test func tremoloStrokesRampAcrossTheHairpin() throws {
        let chord = Chord(
            duration: .whole,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let measure = Measure(voices: [Voice(elements: [
            .dynamic(Dynamic(subtype: "mp", velocity: 64)),
            .spanner(Spanner(
                kind: .hairpin, rawType: "HairPin",
                nextMeasuresOffset: 1,
                hairpin: .init(subtype: .crescendo, veloChange: 40),
            )),
            .chord(chord),
        ])])
        let staff = Staff(measures: [
            measure,
            Measure(voices: [Voice(elements: [.chord(Chord(
                duration: .whole, notes: [Note(pitch: 60, tpc: 14)],
            ))])]),
        ])
        let (events, _, _) = try MidiRenderer.renderVoice(
            voiceIndex: 0,
            staff: staff,
            part: Self.makePart(staff: staff),
            route: MidiRenderer.PartChannelRoute(defaultChannel: 0, defaultPort: 0, switches: []),
            division: 480,
            plan: MidiRenderer.playbackPlan(for: staff.measures, division: 480),
        )
        let strokeVelocities = events
            .filter { $0.tick < 1920 }
            .compactMap { e -> Int? in
                if case let .noteOn(_, _, v) = e.event { return v }
                return nil
            }
        // `1 << subtype.rawValue` strokes, spread over the whole note.
        #expect(strokeVelocities.count == 4)
        #expect(strokeVelocities.first == 64)
        #expect(strokeVelocities.last ?? 0 > 64)
        for i in 1 ..< strokeVelocities.count {
            #expect(
                strokeVelocities[i] >= strokeVelocities[i - 1],
                "stroke \(i) must not fall back below its predecessor",
            )
        }
        #expect(Set(strokeVelocities).count > 1, "the roll must actually swell")
    }
}
