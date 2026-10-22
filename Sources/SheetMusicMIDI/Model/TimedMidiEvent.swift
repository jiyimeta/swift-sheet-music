import SheetMusicCore
import SheetMusicFoundation

/// `MidiEvent` plus the absolute tick at which it occurs.
public struct TimedMidiEvent: Sendable, Equatable {
    public var tick: Int
    public var event: MidiEvent
    /// The microtonal offset of the note a note-on strikes (`Accidental.centOffset`), carried from the emit to
    /// `MicrotonalPitchWheel`, which sounds it as pitch-wheel traffic. Renderer-internal: that pass rebuilds every
    /// event it hands on, so no rendered track carries a non-zero value.
    var tuningCents: Double = 0

    public init(tick: Int, event: MidiEvent) {
        self.tick = tick
        self.event = event
    }

    init(tick: Int, event: MidiEvent, tuningCents: Double) {
        self.tick = tick
        self.event = event
        self.tuningCents = tuningCents
    }
}
