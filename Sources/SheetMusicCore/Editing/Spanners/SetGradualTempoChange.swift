import SheetMusicFoundation

/// Writes a gradual tempo change — a "rit." / "accel." line — over `range`, placed like every other line spanner
/// (`SpannerPlacement`): a `.spanner` `VoiceElement` immediately before the range's first chord, ending at the END
/// TICK of its last element, refused as `.duplicateSpanner` when a gradual tempo change already begins there.
///
/// It carries what MuseScore's palette puts on one (`PaletteCreator::newTempoPalette`,
/// `palette/internal/palettecreator.cpp:1458-1465`): the type, its abbreviation as `beginText` and the same in
/// parentheses as `continueText`, so the line reads `rit.` where it starts and `(rit.)` at the head of each later
/// system. A gradual tempo change has no styled label of its own, so without that text it would draw a bare dashed
/// line; `.undefined`, which has no palette cell, does exactly that.
///
/// `factor` is the target tempo as a multiple of the tempo in force where the change starts; `nil` leaves it to the
/// type's `defaultFactor`, as the palette does. It is stored as given — playback reads it through
/// `GradualTempoChangePayload.effectiveFactor`, which keeps a non-positive or non-finite factor out of the tempo map.
///
/// > Note: This command is sugar over `ReplaceVoiceElements`. See `docs/edit-commands.md`.
public struct SetGradualTempoChange: EditCommand {
    public let range: VoiceElementRange
    public let type: GradualTempoChangeType
    public let factor: Double?

    public init(over range: VoiceElementRange, type: GradualTempoChangeType, factor: Double? = nil) {
        self.range = range
        self.type = type
        self.factor = factor
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let label = type.paletteText
        let template = Spanner(
            kind: .gradualTempoChange, rawType: Spanner.Kind.gradualTempoChange.rawValue, beginText: label,
            gradualTempoChange: .init(type: type, factor: factor), continueText: label.map { "(\($0))" },
        )
        return try SpannerPlacement.add(
            template, over: range, in: score, operation: String(describing: Self.self),
        ).apply(to: &score, ids: &ids)
    }
}
