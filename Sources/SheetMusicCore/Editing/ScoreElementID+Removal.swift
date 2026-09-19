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
        case let .glissando(start): return SetGlissando(at: start, glissando: nil)
        // A swing directive is written system-wide by every host that writes one (`SetSwing.Settings`' own
        // default), so that is the kind this resolver removes. A staff-bound one — which only a file can carry
        // in — is removed through `SetSwing` directly, with the flag its own editor read off the score.
        case let .swing(anchor): return SetSwing(anchor: anchor, settings: nil, isSystemText: true)
        case .dynamic, .fermata, .breath, .tempo, .spanner, .keySignature,
             .timeSignature, .barLine, .articulation:
            return nil
        }
    }
}
