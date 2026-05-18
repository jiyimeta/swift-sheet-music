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

    /// Emit MIDI events for a chord carrying `Chord.tremolo` by
    /// expanding into `tremoloSegments` and laying down a noteOn/Off
    /// pair per segment. For `.between` span, walks forward to find
    /// the next `.chord` in the voice's element list and records its
    /// index in `consumedByTremolo` so the voice walker emits no
    /// independent events for it. The caller advances the running
    /// tick by the start-chord's own duration; the follower's tick
    /// advance is performed by the consumed-skip branch when the loop
    /// reaches the follower index.
    static func renderTremoloChord( // swiftlint:disable:this function_parameter_count
        _ chord: Chord,
        elementIndex: Int,
        voiceElements: [VoiceElement],
        measureDuration: Fraction,
        localTick: inout Int,
        velocity: Int,
        consumedByTremolo: inout Set<Int>,
        channel: Int,
        division: Int,
        events: inout [TimedMidiEvent],
        hairpinRamps: [HairpinRamp],
        ottavaRanges: [OttavaRange],
        originalTickDelta: Int,
    ) throws {
        let chordTicks = chord.duration
            .resolved(in: measureDuration)
            .ticks(division: division)
        var followerChord: Chord?
        if chord.tremolo?.span == .between {
            for j in (elementIndex + 1) ..< voiceElements.count {
                if case let .chord(f) = voiceElements[j] {
                    followerChord = f
                    consumedByTremolo.insert(j)
                    break
                }
            }
        }
        let segments = try MidiRenderer.tremoloSegments(
            for: chord,
            nominalDuration: chordTicks,
            followerChord: followerChord,
        )
        var cursor = localTick
        let pitchShift = OttavaRanges.semitones(
            in: ottavaRanges,
            at: localTick + originalTickDelta,
        )
        let segVelocity = HairpinRamps.active(
            in: hairpinRamps,
            at: localTick + originalTickDelta,
        ).map {
            HairpinRamps.interpolate(
                ramp: $0,
                atOriginalTick: localTick + originalTickDelta,
            )
        } ?? velocity
        for seg in segments {
            for pitch in seg.pitches {
                let shifted = min(127, max(0, pitch + pitchShift))
                events.append(TimedMidiEvent(
                    tick: cursor,
                    event: .noteOn(
                        channel: channel, pitch: shifted, velocity: segVelocity,
                    ),
                ))
                events.append(TimedMidiEvent(
                    tick: cursor + seg.ticks - 1,
                    event: .noteOff(
                        channel: channel, pitch: shifted, velocity: 0,
                    ),
                ))
            }
            cursor += seg.ticks
        }
        // Advance localTick by the start-chord's own duration only.
        // The follower's advance happens via consumedByTremolo skip.
        localTick += chordTicks
    }
}
