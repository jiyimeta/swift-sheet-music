import Foundation

/// Time-ordered sequence of elements within a measure. C++: `mu::engraving::Voice`.
public struct Voice: Sendable, Equatable {
    public var elements: [VoiceElement]

    public init(elements: [VoiceElement]) {
        self.elements = elements
    }
}
