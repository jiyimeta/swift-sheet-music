import SheetMusicFoundation

/// Writes, replaces or (with `nil`) removes the chord symbol on the chord or rest at `location` — MuseScore's
/// Ctrl+K, "nil clears".
///
/// The symbol sits in the voice stream immediately before the element it names, the placement MSCX uses and the
/// layout anchors at the next timed column (`AdjacentElementSlot`; `LayoutEngine+Placement`). A symbol already in
/// the element's attachment run is replaced in place — `name` and `harmonyType` change; parentheses, offsets,
/// `play`, font overrides and visibility survive; none → one is inserted right before the element. A rest is as
/// good a target as a chord: MuseScore parents a chord symbol on any chord-rest's segment (`edit.cpp:884-903`),
/// and a lead sheet's symbols over rests are its ordinary shape.
///
/// `name` is the WHOLE text as the page shows it ("Am7", "bVII", "C/E"): the renderer prefixes a `rootTpc`'s letter
/// to `name` only while one is set (`HarmonyRendering.displayedName`), so this command nils `rootTpc` / `bassTpc`
/// on every write — a MuseScore-authored `<name>m7</name><root>13</root>` re-written as "Dm7" would otherwise read
/// "ADm7". A written symbol therefore carries no transposable root; transposing chord symbols is out of scope
/// (spec 2026-09-02 §3.2 row 73). `name` is trimmed of surrounding whitespace; empty after trimming is refused as
/// `.emptyChordSymbol`.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` (replace) or `ReplaceVoiceElements` (insert /
/// > remove). It exists to give the operation a domain-meaningful name and to own the adjacency rule; callers
/// > can equally construct the equivalent primitive directly. See `docs/edit-commands.md`.
public struct SetChordSymbol: EditCommand {
    public let location: VoiceElementID
    /// The symbol as typed ("Am7", "bVII", "C/E"), or `nil` to remove.
    public let name: String?
    /// Which font row and accidental rule the symbol uses (`Harmony.styleType`); ignored when `name` is `nil`.
    public let harmonyType: HarmonyType

    public init(at location: VoiceElementID, name: String?, harmonyType: HarmonyType = .standard) {
        self.location = location
        self.name = name
        self.harmonyType = harmonyType
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard case .chord = element else {
            throw Self.refused(.wrongElementKind(at: location, expected: .chordOrRest))
        }
        let ref = VoiceRef(location)
        let existing = AdjacentElementSlot.find(.before, of: location, in: score, where: Self.isHarmony)
        guard let name else {
            guard let index = existing,
                  let removal = AdjacentElementSlot.removing(at: index, in: ref, of: score)
            else { throw Self.refused(.targetNotFound(location)) }
            return try removal.apply(to: &score)
        }
        let trimmed = name.trimmingWhitespaceAndNewlines()
        guard !trimmed.isEmpty else { throw Self.refused(.emptyChordSymbol) }
        if let index = existing, case var .harmony(harmony)? = score[location.withElementIndex(index)] {
            harmony.name = trimmed
            harmony.harmonyType = harmonyType
            harmony.rootTpc = nil
            harmony.bassTpc = nil
            return try AdjacentElementSlot.replacing(.harmony(harmony), at: index, in: ref).apply(to: &score)
        }
        guard let insert = AdjacentElementSlot.inserting(
            .harmony(Harmony(name: trimmed, harmonyType: harmonyType)),
            at: AdjacentElementSlot.insertionIndex(.before, of: location.elementIndex), in: ref, of: score,
        ) else { throw Self.refused(.targetNotFound(location)) }
        return try insert.apply(to: &score)
    }

    /// The chord symbol in the attachment run before the chord or rest at `location`, or `nil`.
    static func current(at location: VoiceElementID, in score: Score) -> Harmony? {
        guard let index = AdjacentElementSlot.find(.before, of: location, in: score, where: isHarmony),
              case let .harmony(harmony)? = score[location.withElementIndex(index)]
        else { return nil }
        return harmony
    }

    private static func isHarmony(_ element: VoiceElement) -> Bool {
        if case .harmony = element { true } else { false }
    }
}
