import SheetMusicCore
import SheetMusicFoundation

/// One thing a `<direction>` produced, addressed to a measure, a staff of the part and a tick of that measure.
struct MusicXMLDirectionEvent: Sendable, Equatable {
    enum Payload: Sendable, Equatable {
        /// An element spliced into positional voice 0 of the staff's measure at `tick`.
        case voice(VoiceElement)
    }

    let measure: Int
    let staff: Int
    let tick: Fraction
    let payload: Payload
}
