import SheetMusicFoundation

// The eight line spanners of spec §3.2 rows 63…71. Each is a name and a `Spanner` template over
// `SpannerPlacement`, which owns the placement rule they all share: a `.spanner` `VoiceElement` immediately
// before the range's first chord, ending at the END TICK of the range's last element, refused as
// `.duplicateSpanner` when one of the same kind already begins there. `rawType` is the `<Spanner type="…">`
// attribute MuseScore writes, which is `Spanner.Kind.rawValue` for every one of them.
//
// > Note: These commands are sugar over `ReplaceVoiceElements`. They exist to give each operation a
// > domain-meaningful name; callers can equally construct the equivalent primitive directly. See
// > `docs/edit-commands.md`.

/// Writes a crescendo / diminuendo (or one of MuseScore's two text-line forms) over `range`.
public struct SetHairpin: EditCommand {
    public let range: VoiceElementRange
    public let subtype: Spanner.HairpinPayload.Subtype

    public init(over range: VoiceElementRange, subtype: Spanner.HairpinPayload.Subtype) {
        self.range = range
        self.subtype = subtype
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(
            kind: .hairpin, rawType: Spanner.Kind.hairpin.rawValue, hairpin: .init(subtype: subtype),
        )
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}
