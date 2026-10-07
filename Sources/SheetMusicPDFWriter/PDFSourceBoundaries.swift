import SheetMusicFoundation

/// Proven top-level boundaries used only for offset recovery, never byte patterns inside a payload.
/// If a stream's direct Length does not prove its boundary, recovery fails rather than guessing at endstream.
struct PDFSourceBoundaries {
    var objects: [Int: [Int]] = [:]
    var sections: [Int] = []

    init(_ bytes: [UInt8]) throws {
        var parser = PDFSourceParser(bytes)
        while true {
            parser.skipWhitespaceAndComments()
            guard parser.pos < bytes.count else { return }
            let start = parser.pos
            if let header = parser.parseObjectHeader() {
                guard let value = parser.parseValue() else { throw PDFAppendError.unreadable }
                let end = parser.pos
                if case let .dictionary(dictionary) = value, parser.token() == "stream" {
                    try Self.skipStream(bytes, dictionary: dictionary, parser: &parser)
                } else { parser.pos = end }
                guard parser.token() == "endobj" else { throw PDFAppendError.unreadable }
                objects[header.number, default: []].append(start)
                if value.dictionary?["Type"] == .name("XRef") { sections.append(start) }
            } else {
                switch parser.token() {
                case "xref":
                    sections.append(start)
                    _ = try PDFSourceDocument.classicEntries(&parser)
                    guard parser.parseValue()?.dictionary != nil else { throw PDFAppendError.unreadable }
                case "startxref":
                    guard let offset = Int(parser.token()), offset >= 0 else { throw PDFAppendError.unreadable }
                default: throw PDFAppendError.unreadable
                }
            }
        }
    }

    private static func skipStream(
        _ bytes: [UInt8], dictionary: [String: PDFSourceValue], parser: inout PDFSourceParser,
    ) throws {
        guard let length = dictionary["Length"]?.integer, length >= 0 else { throw PDFAppendError.unreadable }
        if parser.pos < bytes.count, bytes[parser.pos] == 13 { parser.pos += 1 }
        guard parser.pos < bytes.count, bytes[parser.pos] == 10 else { throw PDFAppendError.unreadable }
        parser.pos += 1
        guard length <= bytes.count - parser.pos else { throw PDFAppendError.unreadable }
        parser.pos += length
        guard parser.token() == "endstream" else { throw PDFAppendError.unreadable }
    }

    static func unique(_ offsets: [Int], near offset: Int, byteCount: Int) throws -> Int {
        guard offset >= 0, offset < byteCount else { throw PDFAppendError.unreadable }
        let lower = max(0, offset - 1024)
        let upper = offset + min(1024, byteCount - offset - 1)
        let candidates = offsets.filter { $0 >= lower && $0 <= upper }
        guard candidates.count == 1, let result = candidates.first else { throw PDFAppendError.unreadable }
        return result
    }
}
