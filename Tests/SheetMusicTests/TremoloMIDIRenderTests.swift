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
