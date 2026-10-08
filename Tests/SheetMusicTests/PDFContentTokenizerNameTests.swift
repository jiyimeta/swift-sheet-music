#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @testable import SheetMusicPDF
    import Testing

    /// A content stream's names are read by the same parser as the page's dictionaries, so a font selected by `Tf`
    /// finds its `/Font` entry even when the name is not ASCII.
    struct PDFContentTokenizerNameTests {
        @Test func `a name keeps one character per byte, as a dictionary key does`() {
            let ops = PDFContentTokenizer.tokenize(Array("/F#E3#81#82 12 Tf (x\\)y) Tj".utf8))
            let latin1 = String(String.UnicodeScalarView([0x46, 0xE3, 0x81, 0x82].map { Unicode.Scalar($0) }))
            #expect(ops.map(\.op) == ["Tf", "Tj"])
            #expect(ops.first?.operands == [.name(latin1), .number(12)])
            #expect(ops.last?.operands == [.string(Array("x)y".utf8))])
        }
    }
#endif
