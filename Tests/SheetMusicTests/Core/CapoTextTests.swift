@testable import SheetMusicCore
import Testing

/// `Capo::generateText` (`dom/capo.cpp:144-175`), in English.
@Suite("Capo text")
struct CapoTextTests {
    @Test("a capo on a fret reads 'Capo N'; fret 0 or inactive reads 'No capo'")
    func plainCapo() {
        #expect(Capo(fretPosition: 2, text: "").generatedText(stringCount: nil) == "Capo 2")
        #expect(Capo(fretPosition: 0, text: "").generatedText(stringCount: nil) == "No capo")
        #expect(Capo(isActive: false, fretPosition: 5, text: "").generatedText(stringCount: 6) == "No capo")
    }

    @Test("a partial capo names the strings it applies to, counting from 1")
    func partialCapo() {
        let capo = Capo(fretPosition: 3, ignoredStrings: [1], text: "")
        #expect(capo.generatedText(stringCount: 6) == "Partial capo:\nFret 3 on strings 1, 3, 4, 5, 6")
        #expect(capo.generatedText(stringCount: nil).isEmpty)
        let all = Capo(fretPosition: 3, ignoredStrings: [0, 1], text: "")
        #expect(all.generatedText(stringCount: 2) == "No capo")
    }

    @Test("the file's own text wins")
    func fileTextWins() {
        #expect(Capo(fretPosition: 2, text: "Capodaster 2").displayedText(stringCount: 6) == "Capodaster 2")
        #expect(Capo(fretPosition: 2, text: "").displayedText(stringCount: 6) == "Capo 2")
    }
}
