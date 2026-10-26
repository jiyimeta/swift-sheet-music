import SheetMusicCore
import SheetMusicFoundation

/// The measure's running `mTime` (`MusicXmlParserPass2::measure`): where the next note, `<forward>` or direction
/// sits, as a fraction of a whole note from the start of the measure, and `furthest`, MuseScore's `mDura`.
struct MusicXMLMeasureClock: Sendable, Equatable {
    private(set) var now = Fraction.zeroTick
    private(set) var furthest = Fraction.zeroTick
    /// How far the clock went, padding included — pass 1's `mDura` (`P1:2768-2786`), which a tuplet's padding grows
    /// where pass 2's does not, and which the measure's length is made from.
    private(set) var reach = Fraction.zeroTick

    /// A note or rest of `duration` (`P2:2851-2857`): the clock moves past it and the measure grows to hold it.
    mutating func advance(by duration: Fraction) {
        now += duration
        if furthest.precedes(now) { furthest = now }
        if reach.precedes(now) { reach = now }
    }

    /// The rest an incomplete tuplet is padded with (`P2:2848-2860`): the clock moves past it, but the measure grows
    /// only once a later note reaches past it.
    mutating func pad(by duration: Fraction) {
        now += duration
        if reach.precedes(now) { reach = now }
    }

    /// `<forward>` (`P2:2862-2870`) moves like a note.
    mutating func forward(by duration: Fraction) {
        advance(by: duration)
    }

    /// `<backup>` (`P2:2871-2887`): back by `duration`; to the start when it would pass the start; and to the start
    /// when what is left is under one division (`1 / (4 × divisionsPerQuarter)`), the rounding residue MuseScore
    /// comments on (`P2:2881-2886`).
    mutating func backup(by duration: Fraction, divisionsPerQuarter: Int) {
        if duration.precedes(now) || duration == now {
            now -= duration
        } else {
            now = .zeroTick
        }
        if !now.isZeroTick, divisionsPerQuarter > 0,
           now.precedes(Fraction(numerator: 1, denominator: 4 * divisionsPerQuarter))
        {
            now = .zeroTick
        }
    }
}
