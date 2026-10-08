import SheetMusicFoundation

/// A PDF object (ISO 32000-1 §7.3), as both PDF readers in this package parse it: the importer's whole-file scan and
/// the incremental writer's cross-reference reader.
package indirect enum PDFObject: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    /// A name without its slash, one Unicode scalar per byte (`PDFBytes.latin1`).
    case name(String)
    /// The decoded bytes of a literal `(…)` or hex `<…>` string.
    case string([UInt8])
    case array([PDFObject])
    case dictionary([String: PDFObject])
    /// An indirect reference `N G R`.
    case reference(Int, Int)
    /// A stream's dictionary and its still-encoded payload.
    case stream(dictionary: [String: PDFObject], raw: [UInt8])
}

extension PDFObject {
    /// `.int` only: a real where an integer belongs — a count, an offset, a length — is not read as one.
    package var integerValue: Int? {
        if case let .int(value) = self { value } else { nil }
    }

    /// `.int` widened or `.real`.
    package var doubleValue: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .real(value): value
        default: nil
        }
    }

    package var boolValue: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    package var nameValue: String? {
        if case let .name(value) = self { value } else { nil }
    }

    package var stringBytes: [UInt8]? {
        if case let .string(value) = self { value } else { nil }
    }

    package var arrayValue: [PDFObject]? {
        if case let .array(value) = self { value } else { nil }
    }

    /// The dictionary of a `.dictionary` or a `.stream`.
    package var dictionaryValue: [String: PDFObject]? {
        switch self {
        case let .dictionary(value), let .stream(value, _): value
        default: nil
        }
    }

    package var referenceValue: (number: Int, generation: Int)? {
        if case let .reference(number, generation) = self { (number, generation) } else { nil }
    }

    /// The object as PDF syntax, dictionaries with their keys sorted. A stream's payload is written by whoever writes
    /// the stream object, so a stream serializes as `null` here.
    package var serialized: String {
        switch self {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .real(value): PDFBytes.decimal(value)
        case let .name(value): PDFBytes.name(value)
        case let .string(value): "<" + value.map(PDFBytes.hex).joined() + ">"
        case let .array(value): "[" + value.map(\.serialized).joined(separator: " ") + "]"
        case let .dictionary(value):
            "<< " + value.sorted { $0.key < $1.key }.map { PDFBytes.name($0.key) + " " + $0.value.serialized }
                .joined(separator: " ") + " >>"
        case let .reference(number, generation): "\(number) \(generation) R"
        case .stream: "null"
        }
    }
}
