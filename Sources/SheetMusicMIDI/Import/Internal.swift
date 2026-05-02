import Foundation
import SheetMusicCore

/// One channel-coherent slice of an SMF track. Pass 2 produces
/// these from `MidiFile.tracks`; subsequent passes consume them.
struct ImportTrack {
    var trackIndex: Int // SMF track index this came from
    var trackName: String? // first FF 03 within the slice
    var isDrums: Bool // true → channel-10-only slice
    var programChange: Int? // first program change observed
    var events: [TimedMidiEvent] // sorted by tick, includes meta events
}

/// One measure's worth of one ImportTrack's events plus crossing-note
/// records. Pass 4 produces these.
struct ImportMeasure {
    var startTick: Int
    var endTick: Int
    var measureIndex: Int
    var timeSignature: TimeSignature
    var events: [TimedMidiEvent]
    /// Notes sounding *into* this measure that started in an earlier
    /// measure. Pass 6 turns each into a tieBack-marked chord at the
    /// measure head.
    var carryIns: [CarriedNote]
    /// Notes that *leave* this measure unfinished (noteOff happens in
    /// a later measure). Pass 6 emits a tieForward on the final chord.
    var carryOuts: [CarriedNote]
}

struct CarriedNote: Equatable {
    var pitch: Int
    var channel: Int
    var sourceMeasureIndex: Int
    var noteOnTick: Int
    var noteOffTick: Int
}

/// Output of Pass 5 for a single measure: voice elements plus tuplet
/// ranges (referencing element indices).
struct QuantizedMeasure {
    var elements: [VoiceElement]
    var tuplets: [Tuplet]
}
