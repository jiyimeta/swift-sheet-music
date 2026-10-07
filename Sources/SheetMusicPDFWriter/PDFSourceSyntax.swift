import SheetMusicFoundation

/// Direct PDF values retained while writing an incremental update. Names use one Unicode scalar per byte.
indirect enum PDFSourceValue: Equatable {
    case null, bool(Bool), int(Int), real(Double), name(String), string([UInt8])
    case array([PDFSourceValue]), dictionary([String: PDFSourceValue]), reference(Int, Int)
    case stream(dictionary: [String: PDFSourceValue], raw: [UInt8])

    var serialized: String {
        switch self {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .real(value): PDFSourceBytes.decimal(value)
        case let .name(value): PDFSourceBytes.name(value)
        case let .string(value): "<" + value.map(PDFSourceBytes.hex).joined() + ">"
        case let .array(value): "[" + value.map(\.serialized).joined(separator: " ") + "]"
        case let .dictionary(value):
            "<< " + value.sorted { $0.key < $1.key }.map { PDFSourceBytes.name($0.key) + " " + $0.value.serialized }
                .joined(separator: " ") + " >>"
        case let .reference(number, generation): "\(number) \(generation) R"
        // Stream bodies are emitted separately with their raw payload by the object writer.
        case .stream: "null"
        }
    }

    var integer: Int? {
        if case let .int(value) = self { value } else { nil }
    }

    var numeric: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .real(value): value
        default: nil
        }
    }

    var dictionary: [String: PDFSourceValue]? {
        switch self {
        case let .dictionary(value), let .stream(value, _): value
        default: nil
        }
    }

    var array: [PDFSourceValue]? {
        if case let .array(value) = self { value } else { nil }
    }
}

enum PDFSourceBytes {
    /// Preserve a source real's precision, expanding Swift's exponent notation into PDF decimal syntax.
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        let text = String(value)
        let parts = text.lowercased().split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else {
            return text.contains(".") ? text : text + ".0"
        }
        let mantissa = String(parts[0])
        let negative = mantissa.hasPrefix("-")
        let unsigned = negative ? String(mantissa.dropFirst()) : mantissa
        let digits = unsigned.filter { $0 != "." }
        let integerCount = unsigned.split(separator: ".")[0].count
        let point = integerCount + exponent
        let sign = negative ? "-" : ""
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count {
            return sign + digits + String(repeating: "0", count: point - digits.count) + ".0"
        }
        return sign + digits.prefix(point) + "." + digits.dropFirst(point)
    }

    static func whitespace(_ byte: UInt8) -> Bool {
        [0, 9, 10, 12, 13, 32].contains(byte)
    }

    static func delimiter(_ byte: UInt8) -> Bool {
        [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte)
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
        }
    }

    static func hex(_ byte: UInt8) -> String {
        let text = String(byte, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }

    static func latin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    static func name(_ value: String) -> String {
        "/" + value.unicodeScalars.map { scalar in
            let byte = UInt8(truncatingIfNeeded: scalar.value)
            return (33 ... 126).contains(byte) && byte != 35 && !delimiter(byte)
                ? String(Unicode.Scalar(byte)) : "#" + hex(byte)
        }.joined()
    }
}

/// Bounded recursive-descent syntax reader. Stream framing belongs to PDFSourceDocument.
struct PDFSourceParser {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = max(0, min(pos, bytes.count))
    }

    mutating func skipWhitespaceAndComments() {
        while pos < bytes.count {
            if PDFSourceBytes.whitespace(bytes[pos]) {
                pos += 1
            } else if bytes[pos] == 37 {
                while pos < bytes.count, bytes[pos] != 10, bytes[pos] != 13 {
                    pos += 1
                }
            } else { return }
        }
    }

    mutating func token() -> String {
        skipWhitespaceAndComments()
        let start = pos
        while pos < bytes.count, !PDFSourceBytes.whitespace(bytes[pos]), !PDFSourceBytes.delimiter(bytes[pos]) {
            pos += 1
        }
        return String(bytes: bytes[start ..< pos], encoding: .utf8) ?? ""
    }

    mutating func parseObjectHeader() -> (number: Int, generation: Int)? {
        let saved = pos
        guard let number = Int(token()), number > 0,
              let generation = Int(token()), (0 ... 65535).contains(generation), token() == "obj"
        else {
            pos = saved
            return nil
        }
        return (number, generation)
    }

    mutating func parseValue() -> PDFSourceValue? {
        value(depth: 0)
    }

    private mutating func value(depth: Int) -> PDFSourceValue? {
        guard depth < 64 else { return nil }
        skipWhitespaceAndComments()
        guard pos < bytes.count else { return nil }
        switch bytes[pos] {
        case 47: return .name(name())
        case 40: return literal().map(PDFSourceValue.string)
        case 60:
            if pos + 1 < bytes.count, bytes[pos + 1] == 60 { return dictionary(depth: depth) }
            return hexString().map(PDFSourceValue.string)
        case 91: return array(depth: depth)
        default:
            let text = token()
            switch text {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            if let number = Int(text) {
                let saved = pos
                if number >= 0, let generation = Int(token()), (0 ... 65535).contains(generation), token() == "R" {
                    return .reference(number, generation)
                }
                pos = saved
                return .int(number)
            }
            if let real = Double(text), real.isFinite { return .real(real) }
            return nil
        }
    }

    private mutating func array(depth: Int) -> PDFSourceValue? {
        pos += 1
        var values: [PDFSourceValue] = []
        while true {
            skipWhitespaceAndComments()
            guard pos < bytes.count else { return nil }
            if bytes[pos] == 93 { pos += 1; return .array(values) }
            guard let item = value(depth: depth + 1) else { return nil }
            values.append(item)
        }
    }

    private mutating func dictionary(depth: Int) -> PDFSourceValue? {
        pos += 2
        var values: [String: PDFSourceValue] = [:]
        while true {
            skipWhitespaceAndComments()
            guard pos < bytes.count else { return nil }
            if pos + 1 < bytes.count, bytes[pos] == 62, bytes[pos + 1] == 62 {
                pos += 2; return .dictionary(values)
            }
            guard bytes[pos] == 47 else { return nil }
            let key = name()
            guard let item = value(depth: depth + 1) else { return nil }
            values[key] = item
        }
    }

    private mutating func name() -> String {
        pos += 1
        var value: [UInt8] = []
        while pos < bytes.count, !PDFSourceBytes.whitespace(bytes[pos]), !PDFSourceBytes.delimiter(bytes[pos]) {
            if bytes[pos] == 35, pos + 2 < bytes.count,
               let high = PDFSourceBytes.hexValue(bytes[pos + 1]), let low = PDFSourceBytes.hexValue(bytes[pos + 2])
            {
                value.append(high * 16 + low); pos += 3
            } else { value.append(bytes[pos]); pos += 1 }
        }
        return PDFSourceBytes.latin1(value)
    }

    private mutating func hexString() -> [UInt8]? {
        pos += 1
        var value: [UInt8] = []
        var high: UInt8?
        while pos < bytes.count {
            let byte = bytes[pos]; pos += 1
            if byte == 62 {
                if let high { value.append(high * 16) }
                return value
            }
            if PDFSourceBytes.whitespace(byte) { continue }
            guard let nibble = PDFSourceBytes.hexValue(byte) else { return nil }
            if let first = high { value.append(first * 16 + nibble); high = nil } else { high = nibble }
        }
        return nil
    }

    private mutating func literal() -> [UInt8]? {
        pos += 1
        var nesting = 1
        var value: [UInt8] = []
        while pos < bytes.count {
            var byte = bytes[pos]; pos += 1
            if byte == 92 {
                guard pos < bytes.count else { return nil }
                byte = bytes[pos]; pos += 1
                switch byte {
                case 110: value.append(10)
                case 114: value.append(13)
                case 116: value.append(9)
                case 98: value.append(8)
                case 102: value.append(12)
                case 10: break
                case 13: if pos < bytes.count, bytes[pos] == 10 { pos += 1 }
                case 48 ... 55:
                    var octal = Int(byte - 48)
                    for _ in 0 ..< 2 {
                        if pos < bytes.count, (48 ... 55).contains(bytes[pos]) {
                            octal = octal * 8 + Int(bytes[pos] - 48); pos += 1
                        } else { break }
                    }
                    value.append(UInt8(truncatingIfNeeded: octal))
                default: value.append(byte)
                }
            } else if byte == 40 {
                nesting += 1
                value.append(byte)
            } else if byte == 41 {
                nesting -= 1
                if nesting == 0 { return value }
                value.append(byte)
            } else if byte == 13 {
                if pos < bytes.count, bytes[pos] == 10 { pos += 1 }
                value.append(10)
            } else { value.append(byte) }
        }
        return nil
    }
}
