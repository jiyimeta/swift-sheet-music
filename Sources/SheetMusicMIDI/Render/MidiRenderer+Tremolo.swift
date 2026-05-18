import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Internal segment description for tremolo expansion. Each segment
    /// is a chord-shaped note-on/off pair; the voice walker emits MIDI
    /// events one per segment instead of one per `Chord`.
    struct TremoloSegment: Equatable {
        var pitches: [Int]
        var ticks: Int
    }

    /// Expand a chord's tremolo into a list of `(pitchSet, durationTicks)`
    /// segments. For no-tremolo chords returns a single segment matching
    /// the chord's nominal duration. For two-note tremolo, the caller
    /// must supply `followerChord`; the segment list covers BOTH chords'
    /// time-on-page, so the voice walker must mark the follower chord as
    /// consumed and skip its independent emission.
    ///
    /// Stroke count per chord follows MuseScore's tremolo subtype:
    /// r8 → 2, r16 → 4, r32 → 8 (i.e. `1 << subtype.rawValue`).
    ///
    /// Reference: `engraving/dom/tremolo.cpp` (`Tremolo::tremoloLen`) and
    /// `engraving/playback/renderer/internal/tremolorenderer.cpp`.
    static func tremoloSegments(
        for chord: Chord,
        nominalDuration: Int,
        followerChord: Chord?,
    ) throws -> [TremoloSegment] {
        guard let trem = chord.tremolo else {
            return [TremoloSegment(
                pitches: chord.notes.map(\.pitch),
                ticks: nominalDuration,
            )]
        }
        let strokesPerChord = 1 << Int(trem.subtype.rawValue)
        switch trem.span {
        case .single:
            let dur = nominalDuration / strokesPerChord
            return Array(
                repeating: TremoloSegment(
                    pitches: chord.notes.map(\.pitch),
                    ticks: dur,
                ),
                count: strokesPerChord,
            )
        case .between:
            guard let follower = followerChord else {
                throw SheetMusicError.malformedScore(
                    reason: "Two-note tremolo missing follower at render time",
                )
            }
            // Pair sounds for BOTH nominal durations combined, alternating.
            let totalDuration = nominalDuration * 2
            let totalStrokes = strokesPerChord * 2
            let perStroke = totalDuration / totalStrokes
            return (0 ..< totalStrokes).map { i in
                let src = i.isMultiple(of: 2) ? chord : follower
                return TremoloSegment(
                    pitches: src.notes.map(\.pitch),
                    ticks: perStroke,
                )
            }
        }
    }
}
