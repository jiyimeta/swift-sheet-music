import Foundation

/// A simultaneously-sounding group of notes with a shared duration.
/// C++: `mu::engraving::Chord` (subset).
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    public var notes: [Note]

    public init(duration: NoteDuration, notes: [Note]) {
        self.duration = duration
        self.notes = notes
    }
}
