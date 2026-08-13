import SheetMusicFoundation

/// Syntax failure from `XMLTreeParser`, carried as the `underlying` payload of
/// `SheetMusicError.invalidXML`.
///
/// Replaces the `NSError(domain: "XMLTreeParser")` the Foundation-backed parser
/// used to fabricate, and reports a position so a bad score is diagnosable.
public struct XMLSyntaxError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 1-based line of the offending byte.
    public let line: Int
    /// 1-based column of the offending byte, counted in UTF-8 bytes.
    public let column: Int
    public let message: String

    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var description: String {
        "\(message) at line \(line), column \(column)"
    }
}

// `LocalizedError` is part of the `Foundation` umbrella, which this target
// avoids where `FoundationEssentials` is available. `description` carries the
// same text either way.
#if !canImport(FoundationEssentials)
    extension XMLSyntaxError: LocalizedError {
        public var errorDescription: String? {
            description
        }
    }
#endif
