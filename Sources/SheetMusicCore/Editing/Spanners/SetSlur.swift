import SheetMusicFoundation

/// Slurs the chords of `range` — MuseScore's `S` on a selection.
///
/// A slur is the one spanner this package stores INSIDE the chord (`Chord.spanners`), which is where MuseScore
/// writes it too, and the one whose end offsets point at the last chord's ONSET rather than its end tick: a slur
/// is drawn note-head to note-head. Both facts live in `SpannerPlacement`; this command only names the operation.
///
/// The range narrows to the voice of whichever bound has the earlier onset, and a range holding a single chord is
/// refused (`.noNextChord`) — there is nothing to slur to. A second slur beginning on the same chord is refused
/// (`.duplicateSpanner`), which is what makes re-issuing the intent idempotent (spec §3.2).
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to own the placement rule; callers can equally construct the equivalent primitive directly. See
/// > `docs/edit-commands.md`.
public struct SetSlur: EditCommand {
    public let range: VoiceElementRange

    public init(over range: VoiceElementRange) {
        self.range = range
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(kind: .slur, rawType: Spanner.Kind.slur.rawValue)
        return try SpannerPlacement.add(
            template, over: range, in: score, operation: String(describing: Self.self),
        ).apply(to: &score)
    }
}
