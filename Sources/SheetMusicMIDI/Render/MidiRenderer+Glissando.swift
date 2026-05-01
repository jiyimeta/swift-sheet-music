import Foundation
import SheetMusicCore

extension MidiRenderer {
    // MARK: - Entry point

    // swiftlint:disable:next function_parameter_count
    /// Dispatch a single glissando-bearing note to either a discrete sweep
    /// (chromatic / whiteKeys / blackKeys / diatonic) or a continuous
    /// pitch-bend (portamento). Called from `renderChord` when the note has a
    /// glissando and the next chord's first-note pitch could be resolved.
    /// Honours `tieBack` so a glissando starting on a tied-in note does NOT
    /// re-strike — that would leave a hung MIDI note when the synth tracks
    /// note-on counts (the tie's earlier note-on never sees a matching off).
    static func renderGlissandoNote(
        note: Note,
        glissando: Glissando,
        endPitch: Int,
        startTick: Int,
        durationTicks: Int,
        velocity: Int,
        channel: Int,
        currentKey: Int,
        events: inout [TimedMidiEvent]
    ) {
        let suppressStartOn = note.tieBack != nil
        let suppressFinalOff = note.tieForward != nil
        switch glissando.style {
        case .portamento:
            renderPortamento(
                glissando: glissando,
                startPitch: note.pitch, endPitch: endPitch,
                startTick: startTick, durationTicks: durationTicks,
                velocity: velocity, channel: channel,
                suppressStartOn: suppressStartOn,
                suppressFinalOff: suppressFinalOff,
                events: &events
            )
        case .chromatic, .diatonic, .whiteKeys, .blackKeys:
            renderDiscreteGlissando(
                glissando: glissando,
                startPitch: note.pitch, endPitch: endPitch,
                startTick: startTick, durationTicks: durationTicks,
                velocity: velocity, channel: channel,
                keySignature: currentKey,
                suppressStartOn: suppressStartOn,
                suppressFinalOff: suppressFinalOff,
                events: &events
            )
        }
    }

    // MARK: - Discrete glissando (chromatic / whiteKeys / blackKeys / diatonic)

    // swiftlint:disable:next function_parameter_count
    static func renderDiscreteGlissando(
        glissando: Glissando,
        startPitch: Int,
        endPitch: Int,
        startTick: Int,
        durationTicks: Int,
        velocity: Int,
        channel: Int,
        keySignature: Int,
        suppressStartOn: Bool = false,
        suppressFinalOff: Bool = false,
        events: inout [TimedMidiEvent]
    ) {
        let offsets = glissandoPitchOffsets(
            style: glissando.style, startPitch: startPitch,
            endPitch: endPitch, keySignature: keySignature
        )
        let body = offsets.isEmpty ? [0] : offsets
        let b = body.count

        // MuseScore reserves 33% of the chord for the sweep; the held start
        // pitch occupies the other 67% (compatmidirender.cpp:818).
        let glissandoDuration = durationTicks * 33 / 100
        let heldDuration = durationTicks - glissandoDuration

        guard b >= 2, glissandoDuration >= b else {
            // Not enough material for a sweep — emit the start pitch normally.
            if !suppressStartOn {
                events.append(TimedMidiEvent(
                    tick: startTick,
                    event: .noteOn(channel: channel, pitch: startPitch, velocity: velocity)
                ))
            }
            if !suppressFinalOff {
                events.append(TimedMidiEvent(
                    tick: startTick + durationTicks - 1,
                    event: .noteOff(channel: channel, pitch: startPitch, velocity: 0)
                ))
            }
            return
        }

        var times = easeTimeList(
            segments: b - 1, duration: glissandoDuration,
            easeIn: glissando.easeIn, easeOut: glissando.easeOut
        )
        // Shift indices 1… to place the sweep inside the trailing glissando
        // portion (the held portion consumes times[0…1]).
        let originalTimesOne = times[1]
        for i in 1 ..< times.count {
            times[i] += heldDuration - originalTimesOne
        }

        for i in 0 ..< b {
            let pitch = startPitch + body[i]
            let onTick = startTick + times[i]
            let offTick = (i + 1 < b) ? startTick + times[i + 1] - 1 : startTick + durationTicks - 1
            // Suppress only the held start pitch's note-on (i==0) when the
            // glissando-bearing note ties back to a still-sounding predecessor.
            // We keep its note-off so the held pitch is released cleanly before
            // the sweep takes over (the sweep pitches at i>0 are different
            // pitch numbers, so no MIDI key collision). Sweep pitches always emit.
            if !(i == 0 && suppressStartOn) {
                events.append(TimedMidiEvent(
                    tick: onTick,
                    event: .noteOn(channel: channel, pitch: pitch, velocity: velocity)
                ))
            }
            // Suppress the very last sweep pitch's note-off only when the note
            // ties forward AND that pitch coincides with the next chord's first
            // note — otherwise the discrete sweep ends here. This is rare but
            // harmless to honour.
            let suppressOff = (i == b - 1) && suppressFinalOff
            if !suppressOff {
                events.append(TimedMidiEvent(
                    tick: offTick,
                    event: .noteOff(channel: channel, pitch: pitch, velocity: 0)
                ))
            }
        }
    }

    // MARK: - Portamento (continuous pitch bend)

    // swiftlint:disable:next function_parameter_count
    /// Emit a continuous pitch-bend ramp while the start pitch sustains. The
    /// track header sets pitch-bend sensitivity to 12 semitones (see
    /// `MidiRenderer+Header.swift`); intervals larger than an octave are
    /// clamped to the bend range. A pitch-bend reset is emitted just after
    /// the note-off so the following chord plays at its natural pitch.
    /// `suppressStartOn` / `suppressFinalOff` honour ties: when the source
    /// note ties from the previous chord we must NOT re-attack (the tied
    /// predecessor's note-on is still open — a duplicate note-on without a
    /// matching off causes the synth to keep one of the notes hung until end
    /// of song). Pitch-bend events continue to apply to the held tied note,
    /// so the glissando still glides correctly.
    static func renderPortamento(
        glissando: Glissando,
        startPitch: Int,
        endPitch: Int,
        startTick: Int,
        durationTicks: Int,
        velocity: Int,
        channel: Int,
        suppressStartOn: Bool = false,
        suppressFinalOff: Bool = false,
        events: inout [TimedMidiEvent]
    ) {
        let semitones = Double(endPitch - startPitch)
        let sensitivity = 12.0 // Matches the RPN set in the track header.
        let targetOffset = max(-8192.0, min(8191.0, semitones / sensitivity * 8191.0))

        // Strike the start pitch (unless tied from a still-sounding predecessor);
        // pitch-bend starts at centre.
        if !suppressStartOn {
            events.append(TimedMidiEvent(
                tick: startTick,
                event: .noteOn(channel: channel, pitch: startPitch, velocity: velocity)
            ))
        }
        events.append(TimedMidiEvent(
            tick: startTick,
            event: .pitchBend(channel: channel, value: MidiEvent.pitchBendCenter)
        ))

        // Sample density: one event every ~16 ticks, clamped to [4, 64].
        // Peak lands at offTick − 1 (one tick before the chord's natural end)
        // so the centre-reset at offTick has the WHOLE tick to itself —
        // otherwise a synth that reorders simultaneous events by message
        // type can apply the reset BEFORE the peak and leave the wheel
        // stuck at peak for the rest of the song.
        let offTick = startTick + durationTicks - 1
        let lastSampleTick = max(startTick, offTick - 1)
        let scaleSpan = max(1, lastSampleTick - startTick)
        let sampleCount = max(4, min(64, durationTicks / 16))
        let eIn = glissando.easeIn
        let eOut = glissando.easeOut
        for i in 1 ... sampleCount {
            let t = Double(i) / Double(sampleCount)
            let curved = (eIn == 0 && eOut == 0)
                ? t : xFromYBezier(t, easeIn: Double(eIn) / 100.0, easeOut: Double(eOut) / 100.0)
            let bend = MidiEvent.pitchBendCenter + Int((targetOffset * curved).rounded())
            let sampleTick = startTick + Int((Double(scaleSpan) * t).rounded())
            events.append(TimedMidiEvent(
                tick: sampleTick,
                event: .pitchBend(channel: channel, value: bend)
            ))
        }

        // Release the start note at the chord's natural end (unless the note
        // ties forward — then the next chord owns the release), then reset
        // pitch-bend at the same tick. The reset is now the only pitch-bend
        // event at offTick (peak landed at offTick−1), so any synth — even
        // ones that reorder simultaneous events — sees the reset as the
        // most-recent bend and the wheel returns to centre cleanly.
        if !suppressFinalOff {
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .noteOff(channel: channel, pitch: startPitch, velocity: 0)
            ))
        }
        events.append(TimedMidiEvent(
            tick: offTick,
            event: .pitchBend(channel: channel, value: MidiEvent.pitchBendCenter)
        ))
    }
}
