extension SetElementVisible {
    /// The slot this command takes to show or hide `element` — what a host writes when the user presses `V` on a
    /// selected mark.
    ///
    /// A mark that stands as a voice element of its own is addressed by the chord or rest it belongs to
    /// (`ScoreElementID.anchor`). That is the right target for the command that writes the mark (`SetDynamic`,
    /// `SetFermata`, `SetBreath`), and the wrong one for this command, which would hide the chord and leave the mark
    /// standing. So this resolves the mark's own slot, the way those commands find it: a dynamic or a fermata in the
    /// run before its chord, the breath after it (at the head of the next bar, for a breath the bar's last chord owns),
    /// and a line at its anchor, which names the `.spanner` element itself (`RemoveSpanner`).
    ///
    /// `nil` for a mark written on its chord or note — an articulation, an arpeggio, a chord line, a tremolo, a tie, a
    /// slur, a glissando — which carries no flag this command writes; for a tempo or a swing, which the system carries;
    /// for an element addressed by bar or by staff; and for a mark the score no longer holds.
    public static func slot(of element: ScoreElementID, in score: Score) -> VoiceElementID? {
        switch element {
        case let .dynamic(anchor):
            AdjacentElementSlot.find(.before, of: anchor, in: score, where: isDynamic).map(anchor.withElementIndex)
        case let .fermata(anchor):
            AdjacentElementSlot.find(.before, of: anchor, in: score, where: isFermata).map(anchor.withElementIndex)
        case let .breath(anchor):
            SetBreath.existingSlot(after: anchor, in: score)
        case let .spanner(anchor, _):
            if case .spanner? = score[anchor] { anchor } else { nil }
        case .tempo, .swing, .articulation, .arpeggio, .chordLine, .tremolo, .tie, .slur, .glissando, .keySignature,
             .timeSignature, .barLine, .jump, .marker, .partName:
            nil
        }
    }

    private static func isDynamic(_ element: VoiceElement) -> Bool {
        if case .dynamic = element { true } else { false }
    }

    private static func isFermata(_ element: VoiceElement) -> Bool {
        if case .fermata = element { true } else { false }
    }
}
