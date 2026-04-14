import Foundation
import SheetMusicCore

/// One MIDI event (no timing). Channel events use 0-based channel indices (0..15).
public enum MidiEvent: Sendable, Equatable {
    case noteOn(channel: Int, pitch: Int, velocity: Int)
    case noteOff(channel: Int, pitch: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    case meta(MetaEvent)
    case endOfTrack
}
