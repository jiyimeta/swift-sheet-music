import SheetMusicCore
import SheetMusicFoundation

/// The tempo markings already placed, by measure and tick — what MuseScore's `canAddTempoText` reads off the segment
/// (`importmusicxmlpass2.cpp`, `P2:2692-2707`): a tempo can be added unless one already there plays something other
/// than `Constants::DEFAULT_TEMPO` (2 beats per second). Score-wide, as the score's segments are: every part reads and
/// writes the same registry.
struct MusicXMLTempoRegistry: Sendable, Equatable {
    private struct Key: Hashable, Sendable {
        let measure: Int
        let tick: Fraction
    }

    /// `Constants::DEFAULT_TEMPO` (`constants.h`): a marking of this tempo blocks nothing.
    static let defaultBeatsPerSecond = 2.0

    /// The places that hold a marking with a tempo other than the default.
    private var blocked: Set<Key> = []
    /// Markings MuseScore adds to the segment only once the measure is read (`delayedDirections`, `P2:2984-2990`).
    private var atMeasureEnd: [Key] = []

    func canAdd(measure: Int, tick: Fraction) -> Bool {
        !blocked.contains(Key(measure: measure, tick: tick))
    }

    /// A marking placed now, at `tick` in `measure`.
    mutating func record(measure: Int, tick: Fraction, beatsPerSecond: Double) {
        guard beatsPerSecond != Self.defaultBeatsPerSecond else { return }
        blocked.insert(Key(measure: measure, tick: tick))
    }

    /// A marking MuseScore holds back with the measure's delayed directions: it blocks only from the measure's end.
    mutating func recordAtMeasureEnd(measure: Int, tick: Fraction, beatsPerSecond: Double) {
        guard beatsPerSecond != Self.defaultBeatsPerSecond else { return }
        atMeasureEnd.append(Key(measure: measure, tick: tick))
    }

    /// The measure has been read: the markings held back join the segments.
    mutating func endMeasure() {
        blocked.formUnion(atMeasureEnd)
        atMeasureEnd.removeAll()
    }
}

/// The registry shared by reference across the parts and measures of one import, so a tempo placed by any part blocks
/// the next on that tick: `decodeParts` makes one and every part's walk reads and writes it.
final class MusicXMLTempoRegistryBox {
    var registry = MusicXMLTempoRegistry()
}
