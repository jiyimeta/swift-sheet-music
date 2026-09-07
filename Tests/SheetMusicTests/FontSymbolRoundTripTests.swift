import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<FSymbol>` — MuseScore's "one character from an arbitrary font" element —
/// round-trips without being modeled.
///
/// It is the only remaining entry in the parity doc's standalone-MISSING list,
/// and it needs no model, because of where the format lets it appear. In every
/// reader generation that ships with 4.6.5 — `read400`, `read410` and `read460`
/// — the tag `"FSymbol"` occurs in exactly one place: `readProperties(BSymbol*)`
/// (`read460/tread.cpp:2367`). It is absent from the measure's annotation
/// dispatch and from the `<Note>` reader, so **an `<FSymbol>` can only appear
/// nested inside another symbol**. There it is a child of an element this
/// library models with a bag, and `EngravingSymbol`'s consumed set does not
/// name it, so it survives.
///
/// **This suite is what makes that a measurement rather than a deduction.** No
/// committed fixture carried an `<FSymbol>` before `own/font-symbol.mscx`, so
/// the preservation gate had never once exercised the claim — and that gate
/// `continue`s past a fixture it cannot parse, so its green would have said
/// nothing either way.
@Suite("Font symbol round-trip")
struct FontSymbolRoundTripTests {
    private func fixtureScore() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("font-symbol"))
    }

    private func firstNoteSymbol() throws -> EngravingSymbol {
        let measures = try fixtureScore().parts[0].staves[0].measures
        let chords = measures[0].voices[0].elements.compactMap { element -> Chord? in
            guard case let .chord(chord) = element else { return nil }
            return chord
        }
        let note = try #require(chords.first?.notes.first)
        return try #require(note.symbols.first)
    }

    /// Proves the fixture parses, and that the nested element reaches the bag
    /// of the symbol that contains it rather than being dropped.
    @Test func theNestedFontSymbolReachesTheContainingSymbolsBag() throws {
        let symbol = try firstNoteSymbol()
        #expect(symbol.name == "ornamentTrill")
        let nested = try #require(symbol.preservedMarkup.first { $0.name == "FSymbol" })
        #expect(nested.children.first { $0.name == "font" }?.text == "Edwin")
        #expect(nested.children.first { $0.name == "code" }?.text == "9834")
    }

    @Test func theNestedFontSymbolIsWrittenBackInsideItsSymbol() throws {
        let encoded = try MSCXEncoder.encode(fixtureScore())
        let root = try XMLTreeParser.parse(encoded)
        let note = try #require(
            root.first("Score")?.first("Staff")?.first("Measure")?
                .first("voice")?.first("Chord")?.first("Note"),
        )
        let symbol = try #require(note.first("Symbol"))
        let nested = try #require(symbol.first("FSymbol"))
        #expect(nested.first("font")?.text == "Edwin")
        #expect(nested.first("fontsize")?.text == "10")
        #expect(nested.first("code")?.text == "9834")
    }

    /// If a later slice models `<FSymbol>`, this expectation is the thing that
    /// should be deleted alongside the parity doc's claim — not left passing
    /// against a bag that no longer fills.
    @Test func nothingModelsTheFontSymbol() throws {
        let stripped = try fixtureScore().strippingPreservedMarkup()
        let encoded = try MSCXEncoder.encode(stripped)
        let root = try XMLTreeParser.parse(encoded)
        let symbols = root.first("Score")?.first("Staff")?.first("Measure")?
            .first("voice")?.first("Chord")?.first("Note")?.all("Symbol") ?? []
        let nested = symbols.compactMap { $0.first("FSymbol") }
        #expect(nested.isEmpty)
    }
}
