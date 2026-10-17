import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the dynamic marking on the chord at `location` — MuseScore's
/// dynamics palette, "nil clears".
///
/// The dynamic sits in the voice stream immediately before its chord, the placement MSCX uses
/// (`AdjacentElementSlot`). A dynamic already in the chord's attachment run is replaced in place — subtype, velocity
/// and text change; its play flag, change speed, voice assignment, font overrides and visibility survive; none → one
/// is inserted right before the chord. The velocity is MuseScore's default for the subtype
/// (`Dynamic.defaultVelocity(for:)`), what the decoder fills in when a file omits `<velocity>`.
///
/// **The text is written with the subtype**, as MuseScore's drop writes both (`Dynamic::drop`,
/// `engraving/dom/dynamic.cpp:318-325`): `xmlText` — MuseScore xml text, `Dynamic.customXMLText`'s form — becomes the
/// dynamic's own text, and `nil` makes it print its subtype. So a new subtype never keeps a stale text (import fidelity
/// F4.6), and the palette's own subtype over "subito p" brings back a plain p.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` (replace) or `ReplaceVoiceElements` (insert /
/// > remove). It exists to give the operation a domain-meaningful name and to own the adjacency rule; callers
/// > can equally construct the equivalent primitive directly. See `docs/edit-commands.md`.
public struct SetDynamic: EditCommand {
    public let location: VoiceElementID
    /// The MSCX subtype token (`"pp"`, `"mf"`, `"sfz"`, …), or `nil` to remove.
    public let subtype: String?
    /// The dynamic's own text as MuseScore xml text ("subito <sym>dynamicPiano</sym>"), or `nil` for its subtype's
    /// glyphs. A removal ignores it.
    public let xmlText: String?

    public init(at location: VoiceElementID, subtype: String?, xmlText: String? = nil) {
        self.location = location
        self.subtype = subtype
        self.xmlText = xmlText
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard case let .chord(chord) = element, !chord.notes.isEmpty else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chord))
        }
        let ref = VoiceRef(location)
        let existing = AdjacentElementSlot.find(.before, of: location, in: score, where: Self.isDynamic)
        guard let subtype else {
            guard let index = existing,
                  let removal = AdjacentElementSlot.removing(at: index, in: ref, of: score)
            else { throw Self.refused(.targetNotFound(location)) }
            return try removal.apply(to: &score, ids: &ids)
        }
        if let index = existing, case var .dynamic(dynamic)? = score[location.withElementIndex(index)] {
            dynamic.subtype = subtype
            dynamic.velocity = Dynamic.defaultVelocity(for: subtype)
            dynamic.setCustomText(xmlText: xmlText)
            return try AdjacentElementSlot.replacing(.dynamic(dynamic), at: index, in: ref).apply(to: &score, ids: &ids)
        }
        var fresh = Dynamic(subtype: subtype, velocity: Dynamic.defaultVelocity(for: subtype))
        fresh.setCustomText(xmlText: xmlText)
        guard let insert = AdjacentElementSlot.inserting(
            .dynamic(fresh), at: AdjacentElementSlot.insertionIndex(.before, of: location.elementIndex), in: ref,
            of: score,
        ) else { throw Self.refused(.targetNotFound(location)) }
        return try insert.apply(to: &score, ids: &ids)
    }

    /// The dynamic in the attachment run before the chord at `location`, or `nil`.
    static func current(at location: VoiceElementID, in score: Score) -> Dynamic? {
        guard let index = AdjacentElementSlot.find(.before, of: location, in: score, where: isDynamic),
              case let .dynamic(dynamic)? = score[location.withElementIndex(index)]
        else { return nil }
        return dynamic
    }

    private static func isDynamic(_ element: VoiceElement) -> Bool {
        if case .dynamic = element { true } else { false }
    }
}

extension Dynamic {
    /// Sets the dynamic's own text from MuseScore xml text (`PreservedTextMarkup(xmlText:)`), or — `nil` — makes it
    /// print its subtype. Text without a tag is stored as plain text with no markup, as the decoder stores a `<text>`
    /// without child elements.
    package mutating func setCustomText(xmlText: String?) {
        guard let xmlText else {
            text = nil
            preservedTextMarkup = nil
            return
        }
        let markup = PreservedTextMarkup(xmlText: xmlText)
        text = markup.derivedText
        let hasElements = markup.content.contains { item in
            if case .element = item { true } else { false }
        }
        preservedTextMarkup = hasElements ? markup : nil
    }
}
