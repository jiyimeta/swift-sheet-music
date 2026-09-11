import SheetMusicFoundation

/// Planning for the four `ElementProperties` writes — color, placement, offset and auto-place.
///
/// Factored out of `ScoreEditSession+Planning`'s main switch for the reason that switch states about its own
/// other folds: it sits at SwiftLint's body budget, and four `case let` arms with a no-op check each would put
/// it over.
///
/// Every arm unwraps the CARRIER, not the property's optional value. A carrier that is absent must still reach
/// `apply` so the command refuses it by name; only a present carrier already holding the requested value plans
/// to nil.
extension ScoreEditSession {
    static func propertyCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .setElementColor(target, color):
            if let current = SetElementColor.currentProperties(for: target, in: score), current.color == color {
                return nil
            }
            return SetElementColor(target, color: color)
        case let .setElementPlacement(target, placement):
            if let current = SetElementPlacement.currentProperties(for: target, in: score),
               current.placement == placement { return nil }
            return SetElementPlacement(target, placement: placement)
        case let .setElementOffset(target, offset):
            if let current = SetElementOffset.currentProperties(for: target, in: score),
               current.offset == offset { return nil }
            return SetElementOffset(target, offset: offset)
        case let .setElementAutoplace(target, autoplace):
            if let current = SetElementAutoplace.currentProperties(for: target, in: score),
               current.autoplace == autoplace { return nil }
            return SetElementAutoplace(target, autoplace: autoplace)
        default:
            return nil
        }
    }
}
