import Foundation

/// SMF meta events used by the renderer.
public enum MetaEvent: Sendable, Equatable {
    case trackName(String)
    case timeSignature(numerator: Int, denominator: Int, clocksPerClick: Int, thirtySecondsPerQuarter: Int)
    case keySignature(sharpsFlats: Int, isMinor: Bool)
    case tempo(microsecondsPerQuarter: Int)
    case portChange(port: Int)
}
