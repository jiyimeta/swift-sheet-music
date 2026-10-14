@testable import SheetMusicCore
import Testing

/// MuseScore's marker types as this library models them (`markerTypeTable`, `engraving/dom/marker.cpp:51-62`;
/// `Marker::RIGHT_MARKERS`, `dom/marker.h:87-93`), and what a marker or jump prints when it has no text of its own.
@Suite("Marker kinds")
struct MarkerKindTests {
    private static let plain = RichTextFormat()

    @Test("Da Coda, Da Doppia Coda and a custom marker carry MuseScore's labels and sides (F3.3)")
    func newKinds() {
        #expect(Marker(kind: .daCoda).effectiveLabel == "coda")
        #expect(Marker(kind: .daDoubleCoda).effectiveLabel == "coda")
        #expect(Marker(kind: .user).effectiveLabel.isEmpty)
        #expect(Marker(kind: .daCoda).isRightMarker)
        #expect(Marker(kind: .daDoubleCoda).isRightMarker)
        #expect(!Marker(kind: .user).isRightMarker)
    }

    @Test("the right markers are MuseScore's five, and a marker's side is its kind's")
    func sides() {
        let kinds: [Marker.Kind] = [
            .segno, .varsegno, .coda, .varcoda, .codetta, .fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda, .user,
            .daCapo, .dalSegno, .other,
        ]
        let right = kinds.filter(\.isRightMarker)
        #expect(right == [.fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda])
        for kind in kinds {
            #expect(Marker(kind: kind).isRightMarker == kind.isRightMarker)
        }
    }

    /// Review Focus 1.
    @Test("a marker without text prints its type's MuseScore default — two codas for a codetta (F3.6)")
    func defaultText() {
        let plain = Self.plain
        func lines(_ kind: Marker.Kind) -> [[RichTextRun]] {
            Marker(kind: kind).displayedRichText.lines
        }
        #expect(lines(.segno) == [[.symbol(name: "segno", plain)]])
        #expect(lines(.varsegno) == [[.symbol(name: "segnoSerpent1", plain)]])
        #expect(lines(.coda) == [[.symbol(name: "coda", plain)]])
        #expect(lines(.varcoda) == [[.symbol(name: "codaSquare", plain)]])
        #expect(lines(.codetta) == [[.symbol(name: "coda", plain), .symbol(name: "coda", plain)]])
        #expect(lines(.fine) == [[.text("Fine", plain)]])
        #expect(lines(.toCoda) == [[.text("To Coda", plain)]])
        #expect(lines(.toCodaSym) == [[.text("To ", plain), .symbol(name: "coda", plain)]])
        #expect(lines(.daCoda) == [[.text("Da Coda", plain)]])
        #expect(lines(.daDoubleCoda) == [[.text("Da Doppia Coda", plain)]])
        #expect(lines(.daCapo) == [[.text("D.C.", plain)]])
        #expect(lines(.dalSegno) == [[.text("D.S.", plain)]])
        #expect(lines(.user) == [[]])
        #expect(lines(.other) == [[]])
    }

    @Test("a marker's own text wins over the default: its words, or its runs while the markup is current")
    func ownText() {
        #expect(Marker(kind: .coda, text: "Coda").displayedRichText.lines == [[.text("Coda", Self.plain)]])
        let markup = PreservedTextMarkup(
            content: [.element(.init(name: "b", content: [.characters("Fine")]))], derivedText: "Fine",
        )
        var marker = Marker(kind: .fine, text: "Fine", preservedTextMarkup: markup)
        #expect(marker.displayedRichText.lines == [[.text("Fine", RichTextFormat(bold: true))]])
        marker.text = "Fin"
        #expect(marker.displayedRichText.lines == [[.text("Fin", Self.plain)]])
        let stacked = Marker(kind: .user, text: "a\n\nb").displayedRichText.lines
        #expect(stacked == [[.text("a", Self.plain)], [], [.text("b", Self.plain)]])
    }

    @Test("markup that parses to no runs counts as no text, so the type's default prints")
    func emptyMarkupPrintsDefault() {
        let empty = PreservedTextMarkup(content: [], derivedText: "")
        let marker = Marker(kind: .fine, preservedTextMarkup: empty)
        #expect(marker.displayedRichText.lines == [[.text("Fine", Self.plain)]])
    }

    @Test("a jump prints its runs or its words, and nothing when it has neither")
    func jumpText() {
        let words = Jump(jumpTo: "start", playUntil: "end", text: "D.C.").displayedRichText.lines
        #expect(words == [[.text("D.C.", Self.plain)]])
        #expect(Jump(jumpTo: "start", playUntil: "end").displayedRichText.lines == [[]])
        let markup = PreservedTextMarkup(
            content: [.element(.init(name: "i", content: [.characters("D.C.")])), .characters(" al Fine")],
            derivedText: "D.C. al Fine",
        )
        let jump = Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine", preservedTextMarkup: markup)
        #expect(jump.displayedRichText.lines == [[
            .text("D.C.", RichTextFormat(italic: true)), .text(" al Fine", RichTextFormat(italic: false)),
        ]])
    }
}
