import SheetMusicCore
import SheetMusicFoundation

/// One channel-coherent slice of an SMF track. Pass 2 produces
/// these from `MidiFile.tracks`; subsequent passes consume them.
struct ImportTrack {
    var trackIndex: Int // SMF track index this came from
    var channel: Int? // MIDI channel this slice was peeled from (drums → 9)
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
    /// Velocity of the originating noteOn, so the measures this note
    /// is carried into can stamp the same per-note velocity as the
    /// measure that started it.
    var velocity = 0
}

/// Output of Pass 5 for a single measure: voice elements plus tuplet
/// ranges (referencing element indices).
struct QuantizedMeasure {
    var elements: [VoiceElement]
    var tuplets: [Tuplet]
    /// Tick ranges of each tuplet, parallel to `tuplets`. Used by
    /// `voice()` to re-resolve indices when it rebuilds the element
    /// list with offset-driven grid steps.
    var tupletTickRanges: [Range<Int>]
    /// Tuplet / binary span assignments produced by the quantizer.
    /// `voice()` uses these to snap raw event ticks to the same
    /// grid the quantizer chose, so chord durations land on standard
    /// note values rather than `.fraction` fallbacks.
    var assignments: [MidiImporter.TupletAssignment]
    /// The binary grid (in ticks) the quantizer used. Provides the
    /// fallback resolution when an event tick falls outside every
    /// confirmed assignment.
    var binaryGrid: Int
}
