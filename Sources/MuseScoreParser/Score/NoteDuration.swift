import Foundation

/// Standard note duration. C++: `mu::engraving::TDuration` (subset).
public enum NoteDuration: String, Sendable {
    case whole, half, quarter, eighth, sixteenth, thirtySecond, sixtyFourth

    /// Number of MIDI ticks at a given PPQ division. quarter = 1 * division.
    public func ticks(division: Int) -> Int {
        switch self {
        case .whole:        return 4 * division
        case .half:         return 2 * division
        case .quarter:      return division
        case .eighth:       return division / 2
        case .sixteenth:    return division / 4
        case .thirtySecond: return division / 8
        case .sixtyFourth:  return division / 16
        }
    }

    /// Decode from MuseScore mscx `<durationType>` text values.
    public init?(mscxName: String) {
        switch mscxName {
        case "whole":   self = .whole
        case "half":    self = .half
        case "quarter": self = .quarter
        case "eighth":  self = .eighth
        case "16th":    self = .sixteenth
        case "32nd":    self = .thirtySecond
        case "64th":    self = .sixtyFourth
        default:        return nil
        }
    }
}
