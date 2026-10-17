import SheetMusicCore
import Wirelet

/// Wire projection of `PartNameForm`, the form carried by `ScoreElementIDWire.partName`.
/// A closed wire choice whose declaration order is persistent; append new cases at the end.
@WireFormatChoice
public enum PartNameFormWire {
    case long
    case short

    public init(from value: PartNameForm) {
        switch value {
        case .long: self = .long
        case .short: self = .short
        }
    }

    public func decoded() -> PartNameForm {
        switch self {
        case .long: return .long
        case .short: return .short
        }
    }
}
