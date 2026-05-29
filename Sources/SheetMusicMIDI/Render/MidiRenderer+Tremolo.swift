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
    /// r8 → 2, r16 → 4, r32 → 8, r64 → 16 (i.e. `1 << subtype.rawValue`).
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
                pitches: chord.notes.filter(\.play).map(\.pitch),
                ticks: nominalDuration,
            )]
        }
        let strokesPerChord = 1 << Int(trem.subtype.rawValue)
        switch trem.span {
        case .single:
            let dur = nominalDuration / strokesPerChord
            return Array(
                repeating: TremoloSegment(
                    pitches: chord.notes.filter(\.play).map(\.pitch),
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
                    pitches: src.notes.filter(\.play).map(\.pitch),
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
        emitTremoloSegments(
            segments,
            chord: chord,
            followerChord: followerChord,
            startTick: localTick,
            channel: channel,
            pitchShift: pitchShift,
            velocity: segVelocity,
            events: &events,
        )
        // Advance localTick by the start-chord's own duration only.
        // The follower's advance happens via consumedByTremolo skip.
        localTick += chordTicks
    }

    /// Lay down the note-on/off pairs for an expanded tremolo, honouring
    /// ties so note-on/off counts stay balanced. A pitch tied INTO the
    /// chord (`tieBack`) skips its first-stroke attack — its sound
    /// continues from the preceding chord's still-open note-on. A pitch
    /// tied OUT of it (`tieForward`) skips its last-stroke release so it
    /// flows into the following note. For `.between` span the last
    /// sounding stroke belongs to the follower, so its `tieForward`
    /// governs the final release.
    ///
    /// Balance matters: an unmatched note-on (or note-off) left by an
    /// unhonoured tie cascades through `resolveUnisonOverlap`'s FIFO
    /// note-on/off pairing and stretches a later same-pitch note across
    /// a rest gap into a stuck note. This mirrors the tie contract that
    /// `emitNoteEvents` enforces on the standard chord path.
    private static func emitTremoloSegments(
        _ segments: [TremoloSegment],
        chord: Chord,
        followerChord: Chord?,
        startTick: Int,
        channel: Int,
        pitchShift: Int,
        velocity: Int,
        events: inout [TimedMidiEvent],
    ) {
        let tiedBackPitches = Set(
            chord.notes.filter { $0.tieBack != nil }.map(\.pitch),
        )
        let tieForwardSource: [Note] = chord.tremolo?.span == .between
            ? (followerChord.map { Array($0.notes) } ?? [])
            : Array(chord.notes)
        let tiedForwardPitches = Set(
            tieForwardSource.filter { $0.tieForward != nil }.map(\.pitch),
        )
        var firstSegIndex: [Int: Int] = [:]
        var lastSegIndex: [Int: Int] = [:]
        for (i, seg) in segments.enumerated() {
            for pitch in seg.pitches {
                if firstSegIndex[pitch] == nil { firstSegIndex[pitch] = i }
                lastSegIndex[pitch] = i
            }
        }
        var cursor = startTick
        for (segIndex, seg) in segments.enumerated() {
            for pitch in seg.pitches {
                let shifted = min(127, max(0, pitch + pitchShift))
                let suppressOn = tiedBackPitches.contains(pitch)
                    && firstSegIndex[pitch] == segIndex
                let suppressOff = tiedForwardPitches.contains(pitch)
                    && lastSegIndex[pitch] == segIndex
                if !suppressOn {
                    events.append(TimedMidiEvent(
                        tick: cursor,
                        event: .noteOn(
                            channel: channel, pitch: shifted, velocity: velocity,
                        ),
                    ))
                }
                if !suppressOff {
                    events.append(TimedMidiEvent(
                        tick: cursor + seg.ticks - 1,
                        event: .noteOff(
                            channel: channel, pitch: shifted, velocity: 0,
                        ),
                    ))
                }
            }
            cursor += seg.ticks
        }
    }
}
