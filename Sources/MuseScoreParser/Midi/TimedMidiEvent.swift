import Foundation

/// `MidiEvent` plus the absolute tick at which it occurs.
public struct TimedMidiEvent: Sendable, Equatable {
    public var tick: Int
    public var event: MidiEvent

    public init(tick: Int, event: MidiEvent) {
        self.tick = tick
        self.event = event
    }
}
