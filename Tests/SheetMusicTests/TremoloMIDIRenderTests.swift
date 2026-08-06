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
}
