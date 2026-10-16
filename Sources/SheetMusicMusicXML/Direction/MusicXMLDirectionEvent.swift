import SheetMusicCore
import SheetMusicFoundation

/// One thing a `<direction>` produced, addressed to a measure, a staff of the part and a tick of that measure.
struct MusicXMLDirectionEvent: Sendable, Equatable {
    enum Payload: Sendable, Equatable {
        /// An element spliced into positional voice 0 of the staff's measure at `tick`.
        case voice(VoiceElement)
        /// The start of a spanner in a part-wide slot; `MusicXMLSpannerPairing` closes it against its stop and turns
        /// the pair into a begin side and an end marker (`.voice(.spanner(…))`).
        case spannerStart(MusicXMLSpannerSlot, Spanner)
        /// The stop of the spanner open in a slot, with what the stop element says about the spanner as a whole.
        case spannerStop(MusicXMLSpannerSlot, MusicXMLSpannerStopEdit)
    }

    let measure: Int
    let staff: Int
    let tick: Fraction
    let payload: Payload
}
