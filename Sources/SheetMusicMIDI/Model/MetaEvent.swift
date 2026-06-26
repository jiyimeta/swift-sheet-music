import Foundation
import SheetMusicCore

/// SMF meta events used by the renderer.
public enum MetaEvent: Sendable, Equatable {
    case trackName(String)
    case timeSignature(numerator: Int, denominator: Int, clocksPerClick: Int, thirtySecondsPerQuarter: Int)
    case keySignature(sharpsFlats: Int, isMinor: Bool)
    case tempo(microsecondsPerQuarter: Int)
    case portChange(port: Int)
    /// Free-form marker text, SMF type `0xFF 0x06`. Used for
    /// rehearsal letters and other navigation annotations a DAW
    /// can show on the timeline.
    case marker(String)
    /// A lyric syllable, SMF type `0xFF 0x05`, timed to the chord it is
    /// sung on. Carries the conventions packed by `LyricMidiCodec`
    /// (trailing `"-"` for word continuation, `"_"` for melisma
    /// continuation, empty string for a verse-slot sentinel).
    case lyric(String)
}
