import SheetMusicFoundation
import SheetMusicPDFSyntax

/// Why annotations could not be appended to an existing PDF.
public enum PDFAppendError: Error, Equatable, Sendable {
    /// The file is encrypted and cannot be read here: no cryptography was given, or its security handler, revision or
    /// method is one this package does not implement (a public-key handler, an unknown crypt filter).
    case encrypted
    /// The file is encrypted under a user password, so it cannot be opened, let alone written, without it.
    case passwordRequired
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
        let dictionary: [String: PDFObject]
        let entries: [Int: Location]
    }

    /// What to do with an encrypted file.
    enum Encryption {
        /// Refuse it (`PDFAppendError.encrypted`), as every reader did before the security handler existed.
        case refuse
        /// Open it with these primitives when its user password is empty, decrypting every string and stream read.
        case decrypt(any PDFCryptoPrimitives)
        /// Read only its encryption dictionary (`encryptDictionary`) — the permissions, which need no key.
        case dictionaryOnly
    }

    let bytes: [UInt8]
    let trailer: [String: PDFObject]
    let startXRef: Int
    let lastSectionIsStream: Bool
    let size: Int
    var locations: [Int: Location] = [:]
    var objectStreams: [Int: [Int: PDFObject]] = [:]
    /// The trailer's `/Encrypt` dictionary, resolved; nil for a file that is not encrypted.
    private(set) var encryptDictionary: [String: PDFObject]?
    /// The handler every string and stream is read through; nil unless the file is encrypted and was opened with
    /// `.decrypt`.
    private(set) var security: PDFStandardSecurity?
    /// The encryption dictionary's own object, whose strings are never encrypted.
    private var encryptObject: Int?
    private var loading: Set<Int> = []
    private var boundaries: PDFSourceBoundaries?

    init(_ data: Data, encryption: Encryption = .refuse) throws {
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
        var parser = PDFObjectParser(bytes, at: marker + 9)
        guard let offset = Int(parser.token()), bytes.indices.contains(offset) else {
            throw PDFAppendError.unreadable
        }
        let latest = try Self.section(bytes, at: offset)
        trailer = latest.dictionary
        startXRef = latest.offset
        lastSectionIsStream = latest.isStream
        guard let size = trailer["Size"]?.integerValue, size > 0, trailer["Root"] != nil else {
            throw PDFAppendError.unreadable
        }
        self.size = size
        var visited: Set<Int> = []
        var current: Section? = latest
        var olderSectionEncrypted = false
        while let section = current {
            guard visited.insert(section.offset).inserted else { throw PDFAppendError.unreadable }
            olderSectionEncrypted = olderSectionEncrypted || section.dictionary["Encrypt"] != nil
            var entries = section.entries
            if let hybrid = section.dictionary["XRefStm"]?.integerValue {
                let supplement = try Self.section(bytes, at: hybrid)
                guard supplement.isStream, visited.insert(supplement.offset).inserted else {
                    throw PDFAppendError.unreadable
                }
                olderSectionEncrypted = olderSectionEncrypted || supplement.dictionary["Encrypt"] != nil
                // Merge one hybrid section before older entries compete with newer definitions.
                entries.merge(supplement.entries) { _, streamEntry in streamEntry }
            }
            merge(entries)
            if let previous = section.dictionary["Prev"] {
                guard let offset = previous.integerValue, bytes.indices.contains(offset) else {
                    throw PDFAppendError.unreadable
                }
                current = try Self.section(bytes, at: offset)
            } else { current = nil }
        }
        try openEncryption(encryption, olderSectionEncrypted: olderSectionEncrypted)
    }

    /// Reads the newest trailer's `/Encrypt` per `encryption`. Every update of an encrypted file carries it forward
    /// (ISO 32000-2 §7.5.6), so a file whose older section names one and whose newest does not is not followed.
    private func openEncryption(_ encryption: Encryption, olderSectionEncrypted: Bool) throws {
        guard let encrypt = trailer["Encrypt"] else {
            if olderSectionEncrypted { throw PDFAppendError.encrypted }
            return
        }
        if case .refuse = encryption { throw PDFAppendError.encrypted }
        encryptObject = encrypt.referenceValue?.number
        // Read before `security` exists, so nothing in it is decrypted: its strings never are.
        guard let dictionary = try resolve(encrypt).dictionaryValue else { throw PDFAppendError.unreadable }
        encryptDictionary = dictionary
        guard case let .decrypt(crypto) = encryption else { return }
        let documentID = trailer["ID"]?.arrayValue?.first.flatMap(\.stringBytes) ?? []
        security = try PDFStandardSecurity(encrypt: dictionary, documentID: documentID, crypto: crypto)
    }

    private func merge(_ entries: [Int: Location]) {
        for (number, location) in entries where locations[number] == nil {
            locations[number] = location
        }
    }

    func object(_ number: Int) throws -> PDFObject {
        guard let location = locations[number], location != .free else { return .null }
        guard loading.count < 64, loading.insert(number).inserted else { throw PDFAppendError.unreadable }
        defer { loading.remove(number) }
        switch location {
        case .free: return .null
        case let .offset(offset):
            var parser = PDFObjectParser(bytes, at: offset)
            var header = bytes.indices.contains(offset) ? parser.parseObjectHeader() : nil
            if header?.number != number {
                let recovered = try objectHeader(number, near: offset)
                parser = PDFObjectParser(bytes, at: recovered)
                header = parser.parseObjectHeader()
                guard header?.number == number else { throw PDFAppendError.unreadable }
            }
            return try decrypted(readValue(&parser), number: number, generation: header?.generation ?? 0)
        case let .compressed(stream, index):
            if objectStreams[stream] == nil { try loadObjectStream(stream) }
            guard index >= 0, let value = objectStreams[stream]?[number] else { throw PDFAppendError.unreadable }
            return value
        }
    }

    func resolve(_ value: PDFObject) throws -> PDFObject {
        var value = value
        var visited: Set<Int> = []
        while case let .reference(number, _) = value {
            guard visited.count < 64, visited.insert(number).inserted else { throw PDFAppendError.unreadable }
            value = try object(number)
        }
        return value
    }

    private func readValue(_ parser: inout PDFObjectParser) throws -> PDFObject {
        guard let value = parser.parseValue() else { throw PDFAppendError.unreadable }
        guard case let .dictionary(dictionary) = value else { return value }
        let saved = parser.pos
        if parser.token() != "stream" { parser.pos = saved; return value }
        let length = try dictionary["Length"].flatMap { try resolve($0).integerValue }
        let raw = try Self.rawStream(bytes, parser: &parser, length: length)
        return .stream(dictionary: dictionary, raw: raw)
    }

    /// `value`, object `number` `generation` as read, with its strings and stream payload decrypted (ISO 32000-2
    /// §7.6.2). Left as read: everything in an unencrypted file, the encryption dictionary, cross-reference streams,
    /// a metadata stream the file leaves clear, and a stream whose own `/Crypt` filter is `/Identity`. An object
    /// stream is decrypted here as a stream; the objects inside it are then read as they are (`loadObjectStream`).
    private func decrypted(_ value: PDFObject, number: Int, generation: Int) throws -> PDFObject {
        guard let security, number != encryptObject else { return value }
        guard case let .stream(dictionary, raw) = value else {
            return try Self.mapStrings(value) {
                try security.decrypt($0, number: number, generation: generation, method: security.stringMethod)
            }
        }
        let strings = try Self.mapStrings(.dictionary(dictionary)) {
            try security.decrypt($0, number: number, generation: generation, method: security.stringMethod)
        }.dictionaryValue ?? dictionary
        let type = dictionary["Type"]?.nameValue
        if type == "XRef" || (type == "Metadata" && !security.encryptMetadata) {
            return .stream(dictionary: strings, raw: raw)
        }
        if let filter = Self.cryptFilterName(dictionary) {
            guard filter == "Identity" else { throw PDFAppendError.encrypted }
            return .stream(dictionary: strings, raw: raw)
        }
        let plain = try security.decrypt(raw, number: number, generation: generation, method: security.streamMethod)
        return .stream(dictionary: strings, raw: plain)
    }

    /// `value` with every string, at any depth, replaced by `transform` of its bytes.
    static func mapStrings(_ value: PDFObject, _ transform: ([UInt8]) throws -> [UInt8]) throws -> PDFObject {
        switch value {
        case let .string(bytes): try .string(transform(bytes))
        case let .array(items): try .array(items.map { try mapStrings($0, transform) })
        case let .dictionary(entries): try .dictionary(entries.mapValues { try mapStrings($0, transform) })
        case let .stream(dictionary, raw):
            try .stream(
                dictionary: mapStrings(.dictionary(dictionary), transform).dictionaryValue ?? dictionary, raw: raw,
            )
        default: value
        }
    }

    /// The name of a stream's own crypt filter (`/Filter /Crypt` or a filter array starting with it): `/Identity`
    /// unless its decode parameters name another. Nil when the stream has none.
    private static func cryptFilterName(_ dictionary: [String: PDFObject]) -> String? {
        let filters = dictionary["Filter"]?.arrayValue ?? dictionary["Filter"].map { [$0] } ?? []
        guard filters.first?.nameValue == "Crypt" else { return nil }
        let parameters = dictionary["DecodeParms"]?.arrayValue?.first ?? dictionary["DecodeParms"]
        return parameters?.dictionaryValue?["Name"]?.nameValue ?? "Identity"
    }

    private func objectHeader(_ number: Int, near offset: Int) throws -> Int {
        if boundaries == nil { boundaries = try PDFSourceBoundaries(bytes) }
        return try PDFSourceBoundaries.unique(boundaries?.objects[number] ?? [], near: offset, byteCount: bytes.count)
    }

    private func loadObjectStream(_ number: Int) throws {
        guard case let .stream(dictionary, raw) = try object(number), dictionary["Type"] == .name("ObjStm"),
              let count = dictionary["N"]?.integerValue, count >= 0,
              let first = dictionary["First"]?.integerValue, first >= 0 else { throw PDFAppendError.unreadable }
        let decoded = try Self.decode(raw, dictionary: dictionary)
        guard first <= decoded.count, count <= first / 2 else { throw PDFAppendError.unreadable }
        var header = PDFObjectParser(Array(decoded.prefix(first)))
        var pairs: [(Int, Int)] = []
        for _ in 0 ..< count {
            guard let number = Int(header.token()), number > 0,
                  let offset = Int(header.token()), offset >= 0, offset < decoded.count - first
            else {
                throw PDFAppendError.unreadable
            }
            pairs.append((number, offset))
        }
        var values: [Int: PDFObject] = [:]
        for (index, pair) in pairs.enumerated() {
            guard case let .compressed(stream, declaredIndex) = locations[pair.0], stream == number,
                  index == declaredIndex else { continue }
            var parser = PDFObjectParser(decoded, at: first + pair.1)
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
    let dictionary: [String: PDFObject]
    let space: PDFPageSpace
    /// The page's media box as stated (or inherited), in default user space: left, bottom, right, top.
    let mediaBox: [Double]
}
