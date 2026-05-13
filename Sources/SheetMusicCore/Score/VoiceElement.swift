import Foundation

/// One ordered element of a voice. The order is significant: a
/// voice is a time-ordered sequence of these.
///
/// **Rests are represented as `Chord` values whose `notes` array is
/// empty.** There is no separate `.rest` case — an empty chord
/// occupies tick budget without producing any sounding note. This
/// keeps every voice element down to one shape and means commands
/// that mutate `chord.notes` (e.g. `RemoveNoteFromChord` deleting
/// the last note) leave the score in a valid state automatically.
///
/// Layout / MIDI / MSCX layers dispatch on `chord.notes.isEmpty` to
/// pick rest behaviour; renderers can still use a richer
/// representation (`LayoutElement.rest`) downstream.
///
/// C++: not a single type (heterogeneous segment children).
public enum VoiceElement: Sendable, Equatable {
    case chord(Chord)
    case keySignature(KeySignature)
    case timeSignature(TimeSignature)
    case clef(Clef)
    case barLine(BarLine)
    case dynamic(Dynamic)
    case spanner(Spanner)
    case measureRepeat(MeasureRepeat)
    case fermata(Fermata)
    case harmony(Harmony)
    /// MuseScore `<location><fractions>N/D</fractions></location>`
    /// at voice level — a cursor move that places the next attached
    /// non-temporal element (dynamic, …) at a tick offset from the
    /// natural cursor. The delta is fraction-of-a-whole-note
    /// (resolved against the score's PPQ at consumption time);
    /// negative values jog backwards. C++:
    /// `mu::engraving::Location` for a segment.
    ///
    /// System-level elements (tempo, rehearsal mark, system text,
    /// swing) used to ride on this cursor too; they now live on
    /// `Score.systemMeasures[i].elements` with explicit
    /// `MeasurePosition`s and are routed there by the decoder.
    case locationShift(delta: Fraction)
}

extension VoiceElement {
    /// Construct a rest element of the given duration. Internally
    /// this is `.chord(Chord(duration:..., notes: []))` — see the
    /// type doc for the unified representation.
    public static func rest(duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: []))
    }

    /// True when this element behaves as a rest — i.e. it is a
    /// chord whose `notes` array is empty.
    public var isRest: Bool {
        if case let .chord(c) = self, c.notes.isEmpty { return true }
        return false
    }

    /// Duration in ticks for chord/rest elements. nil for non-timed
    /// elements (clef, key sig, time sig, dynamics, …).
    public func tickCount(division: Int) -> Int? {
        if case let .chord(c) = self {
            return c.duration.ticks(division: division)
        }
        return nil
    }
}
