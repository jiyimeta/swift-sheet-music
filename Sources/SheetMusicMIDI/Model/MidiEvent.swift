import SheetMusicCore
import SheetMusicFoundation

/// One MIDI event (no timing). Channel events use 0-based channel indices (0..15).
public enum MidiEvent: Sendable, Equatable {
    case noteOn(channel: Int, pitch: Int, velocity: Int)
    case noteOff(channel: Int, pitch: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    /// 14-bit pitch-wheel value (0…16383). 8192 = no bend; +ve = bend up.
    /// Sensitivity in semitones is configured via RPN 0:0 — the MIDI header
    /// in this renderer sets it to 12 semitones (one octave).
    case pitchBend(channel: Int, value: Int)
    case meta(MetaEvent)
    case endOfTrack
}

extension MidiEvent {
    /// 14-bit pitch-wheel value representing "no bend".
    public static let pitchBendCenter = 8192
    /// 14-bit pitch-wheel value range.
    public static let pitchBendRange: ClosedRange<Int> = 0 ... 16383
    /// The pitch-bend sensitivity, in semitones, this renderer's track header sets on every pitched channel (RPN 0:0).
    /// A live channel nothing has played on is still at the GM default of 2, so whatever sends it a wheel value scaled
    /// to this has to set it first.
    package static let pitchBendSensitivity = 12

    /// The wheel value that moves a channel `cents` from its keys, at the `pitchBendSensitivity` this renderer's
    /// header sets — how a microtonal accidental's `centOffset` sounds, in a rendered track
    /// (`MicrotonalPitchWheel`) and in a live audition of one note alike.
    public static func pitchBendValue(cents: Double) -> Int {
        let offset = (cents / 100 / Double(pitchBendSensitivity) * 8191).rounded()
        return min(pitchBendRange.upperBound, max(pitchBendRange.lowerBound, pitchBendCenter + Int(offset)))
    }
}
