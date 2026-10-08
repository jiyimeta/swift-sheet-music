import SheetMusicFoundation
import SheetMusicPDFSyntax

extension PDFSourceDocument {
    /// A recognizable section's errors propagate. Recovery needs one proven nearby top-level boundary.
    static func section(_ bytes: [UInt8], at offset: Int) throws -> Section {
        guard bytes.indices.contains(offset) else { throw PDFAppendError.unreadable }
        var parser = PDFObjectParser(bytes, at: offset)
        if parser.token() == "xref" { return try parseSection(bytes, at: offset) }
        parser = PDFObjectParser(bytes, at: offset)
        if parser.parseObjectHeader() != nil { return try parseSection(bytes, at: offset) }
        let boundaries = try PDFSourceBoundaries(bytes)
        let recovered = try PDFSourceBoundaries.unique(boundaries.sections, near: offset, byteCount: bytes.count)
        return try parseSection(bytes, at: recovered)
    }

    private static func parseSection(_ bytes: [UInt8], at offset: Int) throws -> Section {
        var parser = PDFObjectParser(bytes, at: offset)
        if parser.token() == "xref" {
            let entries = try classicEntries(&parser)
            guard case let .dictionary(dictionary) = parser.parseValue() else { throw PDFAppendError.unreadable }
            return Section(offset: offset, isStream: false, dictionary: dictionary, entries: entries)
        }
        parser = PDFObjectParser(bytes, at: offset)
        guard parser.parseObjectHeader() != nil,
              case let .dictionary(dictionary) = parser.parseValue(), dictionary["Type"] == .name("XRef"),
              parser.token() == "stream" else { throw PDFAppendError.unreadable }
        let raw = try rawStream(bytes, parser: &parser, length: dictionary["Length"]?.integerValue)
        let data = try decode(raw, dictionary: dictionary)
        return try Section(
            offset: offset,
            isStream: true,
            dictionary: dictionary,
            entries: streamEntries(data, dictionary: dictionary),
        )
    }

    static func classicEntries(_ parser: inout PDFObjectParser) throws -> [Int: Location] {
        var entries: [Int: Location] = [:]
        while true {
            let token = parser.token()
            if token == "trailer" { return entries }
            guard let start = Int(token), start >= 0, let count = Int(parser.token()), count >= 0,
                  count <= parser.bytes.count / 5, start <= Int.max - count else { throw PDFAppendError.unreadable }
            for number in start ..< start + count {
                guard let offset = Int(parser.token()), offset >= 0,
                      let generation = Int(parser.token()), (0 ... 65535).contains(generation)
                else {
                    throw PDFAppendError.unreadable
                }
                switch parser.token() {
                case "n": entries[number] = .offset(offset)
                case "f": entries[number] = .free
                default: throw PDFAppendError.unreadable
                }
            }
        }
    }

    private static func streamEntries(_ data: [UInt8], dictionary: [String: PDFObject]) throws -> [Int: Location] {
        guard let widthValues = dictionary["W"]?.arrayValue, widthValues.count == 3,
              widthValues.allSatisfy({ $0.integerValue != nil }) else { throw PDFAppendError.unreadable }
        let widths = widthValues.compactMap(\.integerValue)
        guard widths.count == 3,
              widths.allSatisfy({ (0 ... 8).contains($0) }), widths.reduce(0, +) > 0,
              let size = dictionary["Size"]?.integerValue, size > 0 else { throw PDFAppendError.unreadable }
        let rowSize = widths.reduce(0, +)
        let ranges: [Int]
        if let index = dictionary["Index"] {
            guard let values = index.arrayValue, values.allSatisfy({ $0.integerValue != nil }) else {
                throw PDFAppendError.unreadable
            }
            ranges = values.compactMap(\.integerValue)
        } else { ranges = [0, size] }
        guard !ranges.isEmpty, ranges.count.isMultiple(of: 2) else { throw PDFAppendError.unreadable }
        var cursor = 0
        var entries: [Int: Location] = [:]
        for range in stride(from: 0, to: ranges.count, by: 2) {
            let start = ranges[range], count = ranges[range + 1]
            guard start >= 0, count >= 0, start <= Int.max - count,
                  count <= (data.count - cursor) / rowSize else { throw PDFAppendError.unreadable }
            for number in start ..< start + count {
                var fields = [Int]()
                for width in widths {
                    var field = 0
                    for byte in data[cursor ..< cursor + width] {
                        guard field <= (Int.max - Int(byte)) / 256 else { throw PDFAppendError.unreadable }
                        field = field * 256 + Int(byte)
                    }
                    fields.append(field); cursor += width
                }
                let type = widths[0] == 0 ? 1 : fields[0]
                switch type {
                case 0: entries[number] = .free
                case 1: entries[number] = .offset(fields[1])
                case 2: entries[number] = .compressed(stream: fields[1], index: fields[2])
                default: break // Unknown entry types are treated as undefined by ISO 32000.
                }
            }
        }
        return entries
    }
}
