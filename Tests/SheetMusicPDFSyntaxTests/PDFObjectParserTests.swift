import SheetMusicPDFSyntax
import Testing

/// The parser's two readings of malformed syntax: strict for the incremental writer, which must not misread a file it
/// extends, and lenient for the importer, which keeps what it can.
struct PDFObjectParserTests {
    private static func parse(_ source: String, lenient: Bool) -> (value: PDFObject?, end: Int) {
        var parser = PDFObjectParser(Array(source.utf8), lenient: lenient)
        let value = parser.parseValue()
        return (value, parser.pos)
    }

    @Test(arguments: [
        ("[1 2", PDFObject.array([.int(1), .int(2)])),
        ("[1 ) 2]", .array([.int(1)])),
        ("<< /A 1 /B", .dictionary(["A": .int(1)])),
        ("<< /A 1 2 >>", .dictionary(["A": .int(1)])),
        ("<4G1>", .string([0x41])),
        ("<41", .string([0x41])),
        ("(abc", .string(Array("abc".utf8))),
    ])
    func `malformed syntax is nil when strict and what was read when lenient`(source: String, lenient: PDFObject) {
        #expect(Self.parse(source, lenient: false).value == nil)
        #expect(Self.parse(source, lenient: true).value == lenient)
    }

    @Test func `well-formed syntax reads the same either way`() {
        let source = "<< /Kids [3 0 R 4 0 R] /Name (a\\)b) /Hex <4142> /Real -1.5 /Flag true /None null >>"
        let expected = PDFObject.dictionary([
            "Kids": .array([.reference(3, 0), .reference(4, 0)]), "Name": .string(Array("a)b".utf8)),
            "Hex": .string([0x41, 0x42]), "Real": .real(-1.5), "Flag": .bool(true), "None": .null,
        ])
        #expect(Self.parse(source, lenient: false).value == expected)
        #expect(Self.parse(source, lenient: true).value == expected)
    }

    /// A caller that loops for values must move on at a delimiter that starts none; a strict caller stops there.
    @Test func `a stray delimiter is stepped over only when lenient`() {
        #expect(Self.parse(")", lenient: true) == (nil, 1))
        #expect(Self.parse(")", lenient: false) == (nil, 0))
    }

    @Test(arguments: [false, true])
    func `nesting past the limit is refused`(lenient: Bool) {
        let depth = PDFObjectParser.maxDepth + 1
        let source = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let value = Self.parse(source, lenient: lenient).value
        if lenient {
            // The innermost arrays past the limit are dropped; the outer ones are kept.
            #expect(value != nil)
        } else {
            #expect(value == nil)
        }
    }

    /// Names keep every byte, so the writer writes back the name it read and a content-stream name matches the same
    /// name as a dictionary key.
    @Test func `a name keeps its bytes and writes back unchanged`() throws {
        let source = "/F#E3#81#82"
        let value = try #require(Self.parse(source, lenient: false).value)
        #expect(value == .name(PDFBytes.latin1([0x46, 0xE3, 0x81, 0x82])))
        #expect(value.serialized == source)
    }

    @Test func `an unescaped end of line in a literal string reads as one line feed`() {
        #expect(Self.parse("(a\r\nb\rc)", lenient: false).value == .string(Array("a\nb\nc".utf8)))
    }
}
