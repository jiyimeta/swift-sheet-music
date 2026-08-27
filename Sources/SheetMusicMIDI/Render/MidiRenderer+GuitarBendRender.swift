import SheetMusicCore
import SheetMusicFoundation

/// Emission side of the guitar-bend chain: turning the slots
/// `MidiRenderer+GuitarBend.swift` computes into note and pitch-wheel
/// events. Construction and emission are split so neither file grows past
/// what one screen can hold.
extension MidiRenderer {
    /// Wheel value for an offset expressed in quarter tones, at the
    /// 12-semitone sensitivity the track header sets via RPN
    /// (`MidiRenderer+Header.swift`). Same scaling `renderPortamento` uses.
    static func bendWheelValue(quarterTones: Int) -> Int {
        bendWheelValue(semitones: Double(quarterTones) / 2.0)
    }

    private static func bendWheelValue(semitones: Double) -> Int {
        let sensitivity = 12.0
        let offset = max(-8192.0, min(8191.0, semitones / sensitivity * 8191.0))
        return MidiEvent.pitchBendCenter + Int(offset.rounded())
    }

    // swiftlint:disable:next function_parameter_count
    /// Emit one chord's contribution to a bend chain.
    ///
    /// A chain-start slot strikes `basePitch` and emits no note-off; interior
    /// slots emit neither, only wheel traffic; the chain-end slot releases
    /// `basePitch` and resets the wheel. The ramp is confined to the bend's
    /// `[startTimeFactor, endTimeFactor]` window inside this chord and holds
    /// on both sides of it.
    ///
    /// Sampling mirrors `renderPortamento` (`MidiRenderer+Glissando.swift`):
    /// one event every ~16 ticks clamped to [4, 64], and the last wheel event
    /// of the chord lands at `offTick − 1` so a chain-end reset has the whole
    /// `offTick` to itself — otherwise a synth that reorders simultaneous
    /// events by message type can apply the reset BEFORE the peak and leave
    /// the wheel stuck for the rest of the song.
    static func renderBendChainNote(
        note: Note,
        slot: BendChainSlot,
        startTick: Int,
        durationTicks: Int,
        velocity: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        // A muted note (`<play>0</play>`) emits no MIDI. Mirrors the
        // `if (!note->play()) return;` guard in CompatMidiRender::collectNote.
        // `chainCapableNote` already refuses to build a chain through one, so
        // this is belt and braces.
        guard note.play else { return }
        let velocity = note.customizedVelocity(velocity)
        let offTick = startTick + durationTicks - 1
        let lastSampleTick = max(startTick, offTick - 1)
        if slot.isChainStart {
            events.append(TimedMidiEvent(
                tick: startTick,
                event: .noteOn(channel: channel, pitch: slot.basePitch, velocity: velocity),
            ))
        }
        events.append(TimedMidiEvent(
            tick: startTick,
            event: .pitchBend(
                channel: channel,
                value: bendWheelValue(quarterTones: slot.startOffsetQuarterTones),
            ),
        ))
        if let target = slot.targetOffsetQuarterTones {
            appendBendRamp(
                slot: slot, target: target,
                startTick: startTick, durationTicks: durationTicks,
                lastSampleTick: lastSampleTick,
                channel: channel, events: &events,
            )
        }
        if slot.isChainEnd {
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .noteOff(channel: channel, pitch: slot.basePitch, velocity: 0),
            ))
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .pitchBend(channel: channel, value: MidiEvent.pitchBendCenter),
            ))
        }
    }

    // swiftlint:disable:next function_parameter_count
    /// Wheel samples from the slot's start offset to `target`, spread across
    /// the bend's time-factor window and then held to `lastSampleTick`.
    private static func appendBendRamp(
        slot: BendChainSlot,
        target: Int,
        startTick: Int,
        durationTicks: Int,
        lastSampleTick: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        let span = Double(durationTicks)
        let windowEnd = min(
            startTick + Int((span * slot.endTimeFactor).rounded()), lastSampleTick,
        )
        let rampEnd = max(windowEnd, startTick)
        let rampStart = min(
            startTick + Int((span * slot.startTimeFactor).rounded()), rampEnd,
        )
        let rampSpan = rampEnd - rampStart
        let fromSemitones = Double(slot.startOffsetQuarterTones) / 2.0
        let deltaSemitones = Double(target - slot.startOffsetQuarterTones) / 2.0
        let sampleCount = max(4, min(64, durationTicks / 16))
        for i in 1 ... sampleCount {
            let t = Double(i) / Double(sampleCount)
            events.append(TimedMidiEvent(
                tick: rampStart + Int((Double(rampSpan) * t).rounded()),
                event: .pitchBend(
                    channel: channel,
                    value: bendWheelValue(semitones: fromSemitones + deltaSemitones * t),
                ),
            ))
        }
        // A window that closes before the chord does holds the reached offset
        // to the end, so the wheel is unambiguous for the rest of the chord.
        if rampEnd < lastSampleTick {
            events.append(TimedMidiEvent(
                tick: lastSampleTick,
                event: .pitchBend(
                    channel: channel, value: bendWheelValue(quarterTones: target),
                ),
            ))
        }
    }
}
