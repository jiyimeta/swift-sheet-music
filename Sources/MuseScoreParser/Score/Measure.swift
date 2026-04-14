import Foundation

/// A measure (bar) made up of one or more `Voice`s. C++: `mu::engraving::Measure`.
public struct Measure: Sendable, Equatable {
    public var voices: [Voice]

    public init(voices: [Voice]) {
        self.voices = voices
    }
}
