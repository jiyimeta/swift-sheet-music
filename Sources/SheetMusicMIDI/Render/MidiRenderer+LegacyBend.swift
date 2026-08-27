import SheetMusicCore
import SheetMusicFoundation

/// Playback of the pre-4.2 `<Bend>` curve (`Note.legacyBend`): one struck
/// key whose pitch wheel traces the stored `PitchValue` points.
///
/// Unlike a `GuitarBend` chain — where the destination is a NOTATED pitch on
/// a later chord and the chain has to decide which member strikes and which
/// releases — a legacy bend owns its whole shape on one note. All this side
/// needs from the neighbours is how long the key sounds, which is the tie
/// chain's total length.
extension MidiRenderer {
    /// Pitch → total curve ticks for each legacy-bend note of `chord`.
    ///
    /// The span walks the note's tie chain FORWARD through this voice's
    /// elements (a same-pitch, tied-back partner in the next `.chord`
    /// element) and sums their resolved tick lengths — MuseScore's
    /// `getPlayTicksForBend` walks `tieFor()` the same way
    /// (`compat/midi/compatmidirenderinternal.cpp:167`).
    ///
    /// A chain that cannot be completed inside the walk (the partner is in
    /// the next measure, which this element array does not reach) yields NO
    /// entry: the note plays plain, the same refusal `bendChain` applies at
    /// a barline. Half-applying it would emit a curve whose note-off the
    /// tie has already suppressed.
    ///
    /// Three more shapes yield no entry, so the render side never re-guards
    /// them: `play == false` (the curve is silenced, the note still sounds),
    /// fewer than two points (a degenerate decode has no segment to
    /// interpolate), and `tieBack != nil` (a note tied INTO is already
    /// sounding; MuseScore's bend starts at the struck note, and a mid-chain
    /// `<Bend>` does not occur in real files).
    static func legacyBendSpans(
        chord: Chord,
        voiceElements: [VoiceElement],
        elementIndex: Int,
        measureDuration: Fraction,
        division: Int,
    ) -> [Int: Int] {
        func ticks(_ chord: Chord) -> Int {
            chord.duration.resolved(in: measureDuration).ticks(division: division)
        }
        var spans: [Int: Int] = [:]
        for note in chord.notes {
            guard let bend = note.legacyBend, bend.play, bend.points.count >= 2,
                  note.tieBack == nil
            else { continue }
            var total = ticks(chord)
            var current = note
            var index = elementIndex
            var completed = true
            while current.tieForward != nil {
                guard let next = nextChordElement(
                    in: voiceElements, after: index,
                ), let partner = next.chord.notes.first(where: {
                    $0.tieBack != nil && $0.pitch == current.pitch
                }) else {
                    completed = false
                    break
                }
                total += ticks(next.chord)
                index = next.index
                current = partner
            }
            if completed { spans[note.pitch] = total }
        }
        return spans
    }

    /// The next `.chord` element after `index`, with its own index — the
    /// same forward scan `nextChordTicks` performs, returning the chord so
    /// the tie partner can be looked up in it.
    private static func nextChordElement(
        in elements: [VoiceElement], after index: Int,
    ) -> (index: Int, chord: Chord)? {
        guard index + 1 < elements.count else { return nil }
        for i in (index + 1) ..< elements.count {
            if case let .chord(chord) = elements[i] { return (i, chord) }
        }
        return nil
    }

    // swiftlint:disable:next function_parameter_count
    /// Emit one legacy-bend note: struck normally, pitch wheel following
    /// the curve, reset after release. Port of `collectBend`
    /// (`compat/midi/compatmidirenderinternal.cpp:573`): between
    /// consecutive points the wheel follows `y = a·x² + b` with
    /// `a = Δpitch/Δticks²` anchored at the segment start (zero initial
    /// slope), and after the last point HOLDS its pitch to the end.
    /// 50 curve units = 1 semitone (the C++ scale
    /// `2·limit/amplitude/PITCH_FOR_SEMITONE` folds the ×2 in).
    ///
    /// `durationTicks` is this chord's own played span (drives the noteOff
    /// when the note is not tied onward); `totalTicks` is the full tie-chain
    /// span from `legacyBendSpans` (drives the curve's time axis and the
    /// reset position), so a tied head curves across its whole sounding
    /// length rather than compressing the shape into its first chord.
    ///
    /// The wheel reset lands on BOTH paths — an untied note resets with its
    /// own note-off, a tied head one tick past the chain's end, where its
    /// tail's note-off already sits. A missed reset leaves the wheel bent
    /// for every later note on the channel.
    static func renderLegacyBendNote(
        note: Note,
        bend: LegacyBend,
        startTick: Int,
        durationTicks: Int,
        totalTicks: Int,
        velocity: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        // A muted note (`<play>0</play>`) emits no MIDI. Mirrors the
        // `if (!note->play()) return;` guard in CompatMidiRender::collectNote.
        guard note.play, bend.points.count >= 2 else { return }
        let offTick = startTick + durationTicks - 1
        let tiedOnward = note.tieForward != nil
        // Every wheel sample stops one tick short of the reset, so a synth
        // that reorders same-tick messages by type cannot apply the reset
        // BEFORE the last sample and leave the wheel stuck — the same gap
        // `renderBendChainNote` keeps with its `lastSampleTick`. A gate-time
        // shortened note releases before the notated span ends, so the curve
        // is cut at the release rather than running past it.
        let curveEnd = tiedOnward
            ? startTick + totalTicks - 1
            : max(startTick, min(startTick + totalTicks - 1, offTick - 1))
        events.append(TimedMidiEvent(
            tick: startTick,
            event: .noteOn(
                channel: channel,
                pitch: note.pitch,
                velocity: note.customizedVelocity(velocity),
            ),
        ))
        appendLegacyBendCurve(
            bend: bend, startTick: startTick, totalTicks: totalTicks,
            curveEnd: curveEnd, channel: channel, events: &events,
        )
        if tiedOnward {
            // The tail chord emits the note-off; resetting one tick past the
            // chain end keeps the reset clear of the curve's last sample.
            events.append(TimedMidiEvent(
                tick: startTick + totalTicks,
                event: .pitchBend(channel: channel, value: MidiEvent.pitchBendCenter),
            ))
            return
        }
        events.append(TimedMidiEvent(
            tick: offTick,
            event: .noteOff(channel: channel, pitch: note.pitch, velocity: 0),
        ))
        events.append(TimedMidiEvent(
            tick: offTick,
            event: .pitchBend(channel: channel, value: MidiEvent.pitchBendCenter),
        ))
    }

    /// Wheel samples for the whole curve: one parabola per consecutive point
    /// pair, then a hold of the last point's pitch to `curveEnd`.
    ///
    /// Point times are 0…60 (`PitchValue::MAX_TIME`) fractions of the play
    /// span, so they map onto `totalTicks`, not onto this chord's ticks.
    /// Sample density mirrors `appendBendRamp`: roughly one event per 16
    /// ticks, clamped to [4, 64] per segment.
    private static func appendLegacyBendCurve(
        bend: LegacyBend,
        startTick: Int,
        totalTicks: Int,
        curveEnd: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        // The wheel is a latched control, so a sample that repeats the
        // previous one at the same tick says nothing. Clamping to `curveEnd`
        // makes those collisions routine — a segment boundary and the
        // trailing hold both land there — so they are dropped here rather
        // than padding the stream.
        var last: (tick: Int, value: Int)?
        func sample(_ tick: Int, _ curveUnits: Double) {
            let clamped = min(tick, curveEnd)
            let value = bendWheelValue(semitones: curveUnits / 50.0)
            guard last.map({ $0 != (clamped, value) }) ?? true else { return }
            last = (clamped, value)
            events.append(TimedMidiEvent(
                tick: clamped,
                event: .pitchBend(channel: channel, value: value),
            ))
        }
        // `PitchValue::MAX_TIME` (`types/pitchvalue.h`): point times run 0…60.
        let maxTime = 60
        func tick(at time: Int) -> Int {
            startTick + time * totalTicks / maxTime
        }
        for (p0, p1) in zip(bend.points, bend.points.dropFirst()) {
            let t0 = tick(at: p0.time)
            let t1 = tick(at: p1.time)
            // A zero-length or level segment has no parabola: state the
            // pitch once and let the next segment (or the hold) carry on.
            guard t1 > t0, p0.pitch != p1.pitch else {
                sample(t0, Double(p0.pitch))
                continue
            }
            let span = t1 - t0
            let a = Double(p1.pitch - p0.pitch) / Double(span * span)
            let b = Double(p0.pitch)
            let sampleCount = max(4, min(64, span / 16))
            for i in 0 ... sampleCount {
                let x = Int((Double(span) * Double(i) / Double(sampleCount)).rounded())
                sample(t0 + x, a * Double(x) * Double(x) + b)
            }
        }
        // After the last point the wheel HOLDS its pitch to the end of the
        // sounding span (`collectBend`'s trailing fill).
        if let last = bend.points.last {
            sample(curveEnd, Double(last.pitch))
        }
    }
}
