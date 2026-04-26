import Foundation

/// One ordered element of a voice. The order is significant: a voice is a time-ordered
/// sequence of these. C++: not a single type (heterogeneous segment children).
public enum VoiceElement: Sendable, Equatable {
    case chord(Chord)
    case rest(Rest)
    case keySignature(KeySignature)
    case timeSignature(TimeSignature)
    case clef(Clef)
    case barLine(BarLine)
    case tempo(Tempo)
    case dynamic(Dynamic)
    case spanner(Spanner)
    case measureRepeat(MeasureRepeat)
    case fermata(Fermata)
    case staffText(StaffText)
}
