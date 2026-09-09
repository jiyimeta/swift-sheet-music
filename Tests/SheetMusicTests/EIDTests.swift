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

    @Test func roundTripsASpreadOfRepresentativeValues() {
        for raw in [UInt64(0), 1, 63, 64, 4095, 4096, 1 << 32, UInt64.max - 1] {
            let eid = EID(first: raw, second: raw &+ 7)
            #expect(EID(string: eid.stringValue) == eid)
        }
    }

    @Test func rejectsMalformedStrings() {
        // Cases where we and MuseScore genuinely agree the string is invalid.
        #expect(EID(string: "B") == nil) // no separator
        #expect(EID(string: "B_B_B") == nil) // three parts
        #expect(EID(string: "B_?") == nil) // character outside the alphabet
    }

    /// Real MuseScore's decoder is more permissive than ours on malformed
    /// input; we deliberately diverge because its permissiveness lets two
    /// different malformed strings decode to the same identifier. See the
    /// `EID` type's doc comment for the full argument.
    @Test func isStricterThanMuseScoreForMalformedInput() {
        // Real MuseScore: base64StrToInt64("") returns 0 (the reversed loop
        // doesn't execute), and getline-based splitting keeps a leading
        // empty field, so "_B" decodes to the valid-looking EID(0, 1) there.
        // We reject an empty half instead.
        #expect(EID(string: "_B") == nil)
        #expect(EID(string: "B_") == nil)

        // Real MuseScore: base64StrToInt64 has no length check, so a half
        // longer than MAX_UINT64_BASE64_SIZE (11) silently truncates rather
        // than being rejected. We reject it: it cannot have come from any
        // conforming encoder.
        #expect(EID(string: "AAAAAAAAAAAA_A") == nil)
    }

    /// `<<` on `UInt64` silently discards overflowing bits, so before the
    /// guard, an 11-character half whose leading (most-significant) digit is
    /// >= 16 wrapped onto the same value as `(leading digit - 16)`: "B" (1)
    /// and "R" (17) differ only in that leading digit, and both decoded to
    /// `1152921504606846976`. "AAAAAAAAAAB" is the genuine encoding our own
    /// encoder produces for that value (leading digit 1 does not overflow 64
    /// bits), so it must keep decoding successfully; "AAAAAAAAAAR" cannot
    /// have come from any conforming encoder (leading digit 17 does
    /// overflow) and the guard must now reject it — breaking the alias
    /// without also rejecting the value it collided with.
    @Test func rejectsTheOverflowAliasingPair() {
        #expect(EID(string: "AAAAAAAAAAB_A") == EID(first: 1_152_921_504_606_846_976, second: 0))
        #expect(EID(string: "AAAAAAAAAAR_A") == nil)
    }

    /// The property that actually matters: every identifier our own
    /// `stringValue` can produce decodes back to the same value, across a
    /// spread including the zero-digit case and both halves at their
    /// extremes.
    @Test func roundTripsEverythingOurOwnEncoderCanProduce() {
        let values: [UInt64] = [0, 1, 63, 64, .max]
        for first in values {
            for second in values {
                let eid = EID(first: first, second: second)
                #expect(EID(string: eid.stringValue) == eid)
            }
        }
    }

    @Test func invalidIsBothHalvesMaxAndOnlyThat() {
        #expect(EID.invalid.isValid == false)
        // eid.h:39 uses ||, so one max half is still a valid identifier.
        #expect(EID(first: .max, second: 0).isValid)
        #expect(EID(first: 0, second: .max).isValid)
    }
}
