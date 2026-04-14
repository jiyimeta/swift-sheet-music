import Foundation

/// Concert-pitch key signature. C++: `mu::engraving::KeySig`.
public struct KeySignature: Sendable, Equatable {
    /// Sharp/flat count: -7 (Cb) … +7 (C#). 0 = C major / a minor.
    public var concertKey: Int

    public init(concertKey: Int) {
        self.concertKey = concertKey
    }
}
