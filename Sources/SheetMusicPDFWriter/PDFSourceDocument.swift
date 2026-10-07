import SheetMusicFoundation

/// Why annotations could not be appended to an existing PDF.
public enum PDFAppendError: Error, Equatable, Sendable {
    /// Updating encrypted objects requires the original encryption key.
    case encrypted
    /// The file cannot be followed or represented as a safe incremental update.
    case unreadable
    /// A requested zero-based page index lies outside the file's page tree.
    case pageOutOfRange
}

/// An existing PDF's newest trailer, object locations and page tree, for an incremental update.
final class PDFSourceDocument {
    enum Location: Equatable { case offset(Int), compressed(stream: Int, index: Int), free }
    struct Section {
        let offset: Int
        let isStream: Bool
        let dictionary: [String: PDFSourceValue]
        let entries: [Int: Location]
    }

    let bytes: [UInt8]
    let trailer: [String: PDFSourceValue]
    let startXRef: Int
    let lastSectionIsStream: Bool
    let size: Int
    var locations: [Int: Location] = [:]
    var objectStreams: [Int: [Int: PDFSourceValue]] = [:]
    private var loading: Set<Int> = []
    private var boundaries: PDFSourceBoundaries?

    init(_ data: Data) throws {
        bytes = Array(data)
        guard bytes.starts(with: Array("%PDF-".utf8)),
              let marker = Self.find(
                  Array("startxref".utf8),
                  in: bytes,
                  from: max(0, bytes.count - 2048),
                  backwards: true,
              )
        else {
            throw PDFAppendError.unreadable
        }
        var parser = PDFSourceParser(bytes, at: marker + 9)
        guard let offset = Int(parser.token()), bytes.indices.contains(offset) else {
            throw PDFAppendError.unreadable
        }
        let latest = try Self.section(bytes, at: offset)
        trailer = latest.dictionary
        startXRef = latest.offset
        lastSectionIsStream = latest.isStream
        guard let size = trailer["Size"]?.integer, size > 0, trailer["Root"] != nil else {
            throw PDFAppendError.unreadable
        }
        self.size = size
        var visited: Set<Int> = []
        var current: Section? = latest
        while let section = current {
            guard visited.insert(section.offset).inserted else { throw PDFAppendError.unreadable }
            if section.dictionary["Encrypt"] != nil { throw PDFAppendError.encrypted }
            var entries = section.entries
            if let hybrid = section.dictionary["XRefStm"]?.integer {
                let supplement = try Self.section(bytes, at: hybrid)
                guard supplement.isStream, visited.insert(supplement.offset).inserted else {
                    throw PDFAppendError.unreadable
                }
                if supplement.dictionary["Encrypt"] != nil { throw PDFAppendError.encrypted }
                // Merge one hybrid section before older entries compete with newer definitions.
                entries.merge(supplement.entries) { _, streamEntry in streamEntry }
            }
            merge(entries)
            if let previous = section.dictionary["Prev"] {
                guard let offset = previous.integer, bytes.indices.contains(offset) else {
                    throw PDFAppendError.unreadable
                }
                current = try Self.section(bytes, at: offset)
            } else { current = nil }
        }
    }

    private func merge(_ entries: [Int: Location]) {
        for (number, location) in entries where locations[number] == nil {
            locations[number] = location
        }
    }

    func object(_ number: Int) throws -> PDFSourceValue {
        guard let location = locations[number], location != .free else { return .null }
        guard loading.count < 64, loading.insert(number).inserted else { throw PDFAppendError.unreadable }
        defer { loading.remove(number) }
        switch location {
        case .free: return .null
        case let .offset(offset):
            var parser = PDFSourceParser(bytes, at: offset)
            if !bytes.indices.contains(offset) || parser.parseObjectHeader()?.number != number {
                let recovered = try objectHeader(number, near: offset)
                parser = PDFSourceParser(bytes, at: recovered)
                guard parser.parseObjectHeader()?.number == number else { throw PDFAppendError.unreadable }
            }
            return try readValue(&parser)
        case let .compressed(stream, index):
            if objectStreams[stream] == nil { try loadObjectStream(stream) }
            guard index >= 0, let value = objectStreams[stream]?[number] else { throw PDFAppendError.unreadable }
            return value
        }
    }

    func resolve(_ value: PDFSourceValue) throws -> PDFSourceValue {
        var value = value
        var visited: Set<Int> = []
        while case let .reference(number, _) = value {
            guard visited.count < 64, visited.insert(number).inserted else { throw PDFAppendError.unreadable }
            value = try object(number)
        }
        return value
    }

    private func readValue(_ parser: inout PDFSourceParser) throws -> PDFSourceValue {
        guard let value = parser.parseValue() else { throw PDFAppendError.unreadable }
        guard case let .dictionary(dictionary) = value else { return value }
        let saved = parser.pos
        if parser.token() != "stream" { parser.pos = saved; return value }
        let length = try dictionary["Length"].flatMap { try resolve($0).integer }
        let raw = try Self.rawStream(bytes, parser: &parser, length: length)
        return .stream(dictionary: dictionary, raw: raw)
    }

    private func objectHeader(_ number: Int, near offset: Int) throws -> Int {
        if boundaries == nil { boundaries = try PDFSourceBoundaries(bytes) }
        return try PDFSourceBoundaries.unique(boundaries?.objects[number] ?? [], near: offset, byteCount: bytes.count)
    }

    private func loadObjectStream(_ number: Int) throws {
        guard case let .stream(dictionary, raw) = try object(number), dictionary["Type"] == .name("ObjStm"),
              let count = dictionary["N"]?.integer, count >= 0,
              let first = dictionary["First"]?.integer, first >= 0 else { throw PDFAppendError.unreadable }
        let decoded = try Self.decode(raw, dictionary: dictionary)
        guard first <= decoded.count, count <= first / 2 else { throw PDFAppendError.unreadable }
        var header = PDFSourceParser(Array(decoded.prefix(first)))
        var pairs: [(Int, Int)] = []
        for _ in 0 ..< count {
            guard let number = Int(header.token()), number > 0,
                  let offset = Int(header.token()), offset >= 0, offset < decoded.count - first
            else {
                throw PDFAppendError.unreadable
            }
            pairs.append((number, offset))
        }
        var values: [Int: PDFSourceValue] = [:]
        for (index, pair) in pairs.enumerated() {
            guard case let .compressed(stream, declaredIndex) = locations[pair.0], stream == number,
                  index == declaredIndex else { continue }
            var parser = PDFSourceParser(decoded, at: first + pair.1)
            guard let value = parser.parseValue() else { throw PDFAppendError.unreadable }
            values[pair.0] = value
        }
        objectStreams[number] = values
    }

    static func find(
        _ needle: [UInt8],
        in bytes: [UInt8],
        from: Int,
        to: Int? = nil,
        backwards: Bool = false,
    ) -> Int? {
        let end = min(to ?? bytes.count, bytes.count)
        guard from >= 0, !needle.isEmpty, end >= from, needle.count <= end - from else { return nil }
        let positions = from ... end - needle.count
        if backwards {
            for start in positions.reversed() where bytes[start ..< start + needle.count].elementsEqual(needle) {
                return start
            }
        } else {
            for start in positions where bytes[start ..< start + needle.count].elementsEqual(needle) {
                return start
            }
        }
        return nil
    }
}

struct PDFSourcePage: Equatable {
    let number: Int
    let generation: Int
    let dictionary: [String: PDFSourceValue]
    let space: PDFPageSpace
}
