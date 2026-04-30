@testable import SheetMusicCore
import Testing

@Suite("NoteInputKeyMap")
struct NoteInputKeyMapTests {
    @Test("Letter C in octave 4 maps to MIDI 60, TPC 14")
    func cFour() {
        let r = NoteInputKeyMap.pitch(forLetter: "c", octave: 4)
        #expect(r?.pitch == 60)
        #expect(r?.tpc == 14)
    }

    @Test("Letter G in octave 4 maps to MIDI 67, TPC 15")
    func gFour() {
        let r = NoteInputKeyMap.pitch(forLetter: "g", octave: 4)
        #expect(r?.pitch == 67)
        #expect(r?.tpc == 15)
    }

    @Test("Letter B in octave 5 maps to MIDI 83, TPC 19")
    func bFive() {
        let r = NoteInputKeyMap.pitch(forLetter: "b", octave: 5)
        #expect(r?.pitch == 83)
        #expect(r?.tpc == 19)
    }

    @Test("Non-letter key returns nil")
    func nonLetter() {
        #expect(NoteInputKeyMap.pitch(forLetter: "x", octave: 4) == nil)
        #expect(NoteInputKeyMap.pitch(forLetter: "1", octave: 4) == nil)
    }

    @Test("Uppercase letter is accepted")
    func uppercase() {
        let r = NoteInputKeyMap.pitch(forLetter: "C", octave: 4)
        #expect(r?.pitch == 60)
    }
}
