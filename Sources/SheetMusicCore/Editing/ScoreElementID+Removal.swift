extension ScoreElementID {
    /// The command that removes exactly this element; address validation happens when the command is applied.
    /// The previous twelve visual kinds have no removal command through this resolver yet and return nil.
    public var removalCommand: (any EditCommand)? {
        switch self {
        case let .tie(start, end): return RemoveTie(start: start, end: end)
        case let .slur(id): return RemoveSlur(id)
        case let .jump(staff, measureIndex, index):
            return RemoveJump(staff: staff, measureIndex: measureIndex, index: index)
        case let .marker(staff, measureIndex, index):
            return RemoveMarker(staff: staff, measureIndex: measureIndex, index: index)
        case .dynamic, .fermata, .breath, .tempo, .spanner, .keySignature,
             .timeSignature, .barLine, .articulation:
            return nil
        }
    }
}
