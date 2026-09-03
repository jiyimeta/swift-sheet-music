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

/// Writes a sustain-pedal line over `range`.
public struct SetPedal: EditCommand {
    public let range: VoiceElementRange

    public init(over range: VoiceElementRange) {
        self.range = range
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(kind: .pedal, rawType: Spanner.Kind.pedal.rawValue)
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}

/// Writes an ottava (octave transposition) line over `range`.
public struct SetOttava: EditCommand {
    public let range: VoiceElementRange
    public let subtype: Spanner.OttavaPayload.Subtype

    public init(over range: VoiceElementRange, subtype: Spanner.OttavaPayload.Subtype) {
        self.range = range
        self.subtype = subtype
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(
            kind: .ottava, rawType: Spanner.Kind.ottava.rawValue, ottava: .init(subtype: subtype),
        )
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}

/// Writes a generic text line over `range`. `text` is trimmed
/// (`trimmingWhitespaceAndNewlines()`) before being stored; a text line
/// without a label is a perfectly good line, so an empty trimmed result
/// becomes `beginText: nil` rather than a refusal — exactly what
/// MuseScore's absent `<beginText>` means, unlike a rehearsal mark or a
/// staff text where empty text is meaningless.
public struct SetTextLine: EditCommand {
    public let range: VoiceElementRange
    public let text: String?

    public init(over range: VoiceElementRange, text: String?) {
        self.range = range
        self.text = text
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let trimmed = text?.trimmingWhitespaceAndNewlines()
        let template = Spanner(
            kind: .textLine, rawType: Spanner.Kind.textLine.rawValue,
            beginText: (trimmed?.isEmpty ?? true) ? nil : trimmed,
        )
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}

/// Writes a trill line over `range`.
public struct SetTrill: EditCommand {
    public let range: VoiceElementRange
    public let type: TrillType

    public init(over range: VoiceElementRange, type: TrillType) {
        self.range = range
        self.type = type
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(
            kind: .trill, rawType: Spanner.Kind.trill.rawValue, trill: .init(type: type),
        )
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}

/// Writes a vibrato line over `range`.
public struct SetVibrato: EditCommand {
    public let range: VoiceElementRange
    public let type: VibratoType

    public init(over range: VoiceElementRange, type: VibratoType) {
        self.range = range
        self.type = type
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(
            kind: .vibrato, rawType: Spanner.Kind.vibrato.rawValue, vibrato: .init(type: type),
        )
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}

/// Writes a palm-mute line over `range`.
public struct SetPalmMute: EditCommand {
    public let range: VoiceElementRange

    public init(over range: VoiceElementRange) {
        self.range = range
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(kind: .palmMute, rawType: Spanner.Kind.palmMute.rawValue)
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}

/// Writes a let-ring line over `range`.
public struct SetLetRing: EditCommand {
    public let range: VoiceElementRange

    public init(over range: VoiceElementRange) {
        self.range = range
    }

    public var affectedLocation: VoiceElementID {
        range.start
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let template = Spanner(kind: .letRing, rawType: Spanner.Kind.letRing.rawValue)
        return try SpannerPlacement.add(template, over: range, in: score).apply(to: &score)
    }
}
