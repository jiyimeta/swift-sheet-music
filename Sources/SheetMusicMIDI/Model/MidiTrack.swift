import Foundation
import SheetMusicCore

/// One SMF track: an ordered list of timed events.
public struct MidiTrack: Sendable, Equatable {
    public var events: [TimedMidiEvent]

    public init(events: [TimedMidiEvent] = []) {
        self.events = events
    }
}
