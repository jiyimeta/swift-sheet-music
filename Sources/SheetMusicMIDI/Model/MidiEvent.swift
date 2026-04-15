import Foundation
import SheetMusicCore

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
    public static let pitchBendRange: ClosedRange<Int> = 0...16383
}
