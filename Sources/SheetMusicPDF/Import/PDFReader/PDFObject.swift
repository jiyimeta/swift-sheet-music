#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// A parsed PDF object (COS object). Streams keep their still-encoded raw
/// bytes; `PDFReaderDocument` applies `/FlateDecode` on demand.
indirect enum PDFObject {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    /// A name, without the leading slash (e.g. `Type`, `FlateDecode`).
    case name(String)
    /// Decoded bytes of a literal `(…)` or hex `<…>` string.
    case string([UInt8])
    case array([PDFObject])
    case dictionary([String: PDFObject])
    /// An indirect reference `N G R`.
    case reference(Int, Int)
    /// A stream: its dictionary plus the raw (still-encoded) bytes.
    case stream(dict: [String: PDFObject], raw: [UInt8])
}

extension PDFObject {
    /// Numeric value as `Int` (`.int` directly, `.real` truncated).
    var intValue: Int? {
        switch self {
        case let .int(n): return n
        case let .real(r): return Int(r)
        default: return nil
        }
    }

    /// Numeric value as `Double` (`.int` widened, `.real` directly).
    var doubleValue: Double? {
        switch self {
        case let .int(n): return Double(n)
        case let .real(r): return r
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var nameValue: String? {
        if case let .name(s) = self { return s }
        return nil
    }

    var stringBytes: [UInt8]? {
        if case let .string(b) = self { return b }
        return nil
    }

    var arrayValue: [PDFObject]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// Dictionary payload — for both `.dictionary` and `.stream` objects.
    var dictionaryValue: [String: PDFObject]? {
        switch self {
        case let .dictionary(d): return d
        case let .stream(d, _): return d
        default: return nil
        }
    }

    var referenceValue: (Int, Int)? {
        if case let .reference(n, g) = self { return (n, g) }
        return nil
    }
}
