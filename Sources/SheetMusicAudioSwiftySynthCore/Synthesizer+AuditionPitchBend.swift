import SheetMusicMIDI
import SwiftySynth

extension Synthesizer {
    /// Puts `channel`'s pitch wheel at `value` for an audition — a microtonal note's offset, or the center to undo one
    /// (`NotePreviewPolicy`'s `PreviewPlan.pitchBends`).
    ///
    /// Sets the channel's bend sensitivity to the renderer's (RPN 0:0) before the wheel: `value` is scaled to it
    /// (`MidiEvent.pitchBendValue(cents:)`), and a channel no playback has reached yet — or one a sequencer reset
    /// since — is at the GM default of 2 semitones, which would bend it a sixth as far. The RPN is closed again
    /// (127/127) so a later data entry moves nothing.
    ///
    /// The one place a SwiftySynth host says this: the Apple backend (`SwiftySynthBackend.sendPitchBend`) and Android's
    /// `HostedSynth.pitchBend` both send it, so an audition bends by the same amount on both.
    public func sendAuditionPitchBend(channel: Int, value: UInt16) {
        func controlChange(_ controller: Int, _ data: Int) {
            processMidiMessage(channel: channel, command: 0xB0, data1: controller, data2: data)
        }
        controlChange(101, 0)
        controlChange(100, 0)
        controlChange(6, MidiEvent.pitchBendSensitivity)
        controlChange(38, 0)
        controlChange(101, 127)
        controlChange(100, 127)
        processMidiMessage(channel: channel, command: 0xE0, data1: Int(value & 0x7F), data2: Int((value >> 7) & 0x7F))
    }
}
