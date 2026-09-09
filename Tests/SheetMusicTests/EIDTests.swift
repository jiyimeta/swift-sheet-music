@testable import SheetMusicCore
import Testing

@Suite("EID")
struct EIDTests {
    /// The value that actually appears in this repository's own corpus:
    /// `Tests/SheetMusicTests/Resources/midi01.mscx:4` is `<eid>B_B</eid>`,
    /// written by MuseScore 4.6. Alphabet index 1 is "B", so this is (1, 1).
    @Test func decodesTheValueMuseScoreWroteIntoOurFixture() {
        let eid = EID(string: "B_B")
        #expect(eid == EID(first: 1, second: 1))
    }

    @Test func encodesBackToTheSameString() {
        #expect(EID(first: 1, second: 1).stringValue == "B_B")
    }

    @Test func zeroIsASingleCharacter() {
        // The C++ uses do-while, so zero emits one digit rather than none.
        #expect(EID(first: 0, second: 0).stringValue == "A_A")
        #expect(EID(string: "A_A") == EID(first: 0, second: 0))
    }

    @Test func digitsAreLeastSignificantFirst() {
        // 64 == 1 * 64 + 0, emitted low digit first: "A" then "B".
        #expect(EID(first: 64, second: 0).stringValue == "AB_A")
        #expect(EID(string: "AB_A") == EID(first: 64, second: 0))
    }

    @Test func roundTripsAcrossTheWholeAlphabet() {
        for raw in [UInt64(0), 1, 63, 64, 4095, 4096, 1 << 32, UInt64.max - 1] {
            let eid = EID(first: raw, second: raw &+ 7)
            #expect(EID(string: eid.stringValue) == eid)
        }
    }

    @Test func rejectsMalformedStrings() {
        #expect(EID(string: "B") == nil) // no separator
        #expect(EID(string: "B_B_B") == nil) // three parts
        #expect(EID(string: "B_") == nil) // empty half
        #expect(EID(string: "B_?") == nil) // character outside the alphabet
        #expect(EID(string: "AAAAAAAAAAAA_A") == nil) // half longer than 11
    }

    @Test func invalidIsBothHalvesMaxAndOnlyThat() {
        #expect(EID.invalid.isValid == false)
        // eid.h:39 uses ||, so one max half is still a valid identifier.
        #expect(EID(first: .max, second: 0).isValid)
        #expect(EID(first: 0, second: .max).isValid)
    }
}
