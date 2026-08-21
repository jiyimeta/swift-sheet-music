#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// `SimpleFontTextDecoder` — a simple font's 1-byte CHARACTER CODE → the
    /// text it stands for, through `/Encoding /Differences` first and the
    /// declared base encoding second.
    ///
    /// Measured on the real Finale PDFs: their Latin text fonts (Times New
    /// Roman) declare `/Encoding /MacRomanEncoding`, carry NO `/ToUnicode`
    /// and NO `/Differences`, so every byte above 0x7F was being read as
    /// Latin-1 — `0xD5` came out `Õ` where the file says `’`.
    struct SimpleFontTextDecoderTests {
        /// Nothing to say ⇒ no decoder, and the caller keeps its legacy
        /// whole-run decode. Identity-H is the important case: those are
        /// 2-byte codes, so byte-at-a-time decoding must NOT engage.
        @Test func aFontWithNothingDeclaredHasNoDecoder() {
            #expect(SimpleFontTextDecoder(differences: [:], baseEncoding: "") == nil)
            #expect(SimpleFontTextDecoder(differences: [:], baseEncoding: "Identity-H") == nil)
            #expect(SimpleFontTextDecoder(differences: [:], baseEncoding: "MacExpertEncoding") == nil)
        }

        @Test func theDeclaredBaseEncodingDecodesTheUpperHalf() {
            let decoder = SimpleFontTextDecoder(differences: [:], baseEncoding: "MacRomanEncoding")
            #expect(decoder?.text(code: 0xD5) == "\u{2019}")
            #expect(decoder?.text(code: 0xC9) == "\u{2026}")
            let winAnsi = SimpleFontTextDecoder(differences: [:], baseEncoding: "WinAnsiEncoding")
            #expect(winAnsi?.text(code: 0x92) == "\u{2019}")
        }

        /// `/Differences` overrides the base encoding for the codes it names
        /// — that is what the array is for.
        @Test func aDifferencesNameWinsOverTheBaseEncoding() {
            let decoder = SimpleFontTextDecoder(
                differences: [0xD5: "eacute"], baseEncoding: "MacRomanEncoding",
            )
            #expect(decoder?.text(code: 0xD5) == "\u{00E9}")
        }

        /// A name no glyph list knows (subsetting synthesizes these) leaves
        /// the base encoding as the next-best answer rather than dropping
        /// the character.
        @Test func anUnreadableDifferencesNameFallsBackToTheBaseEncoding() {
            let decoder = SimpleFontTextDecoder(
                differences: [0xD5: "gid12"], baseEncoding: "MacRomanEncoding",
            )
            #expect(decoder?.text(code: 0xD5) == "\u{2019}")
        }

        @Test func aCodeNothingCanAnswerDeclines() {
            let decoder = SimpleFontTextDecoder(differences: [0x41: "eacute"], baseEncoding: "")
            #expect(decoder?.text(code: 0x42) == nil)
        }

        /// Whole-operand decoding: an unanswerable code keeps the raw byte
        /// (the behavior every caller had before), so text is never lost.
        @Test func decodeKeepsTheRawByteForAnUnanswerableCode() {
            let decoder = SimpleFontTextDecoder(differences: [0x41: "eacute"], baseEncoding: "")
            #expect(decoder?.decode([0x41, 0xD5]) == "\u{00E9}\u{00D5}")
        }

        @Test func asciiIsUnchanged() {
            let decoder = SimpleFontTextDecoder(differences: [:], baseEncoding: "MacRomanEncoding")
            #expect(decoder?.decode(Array("Andante".utf8)) == "Andante")
        }
    }
#endif
