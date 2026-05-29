import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Public façade that turns mscx XML bytes into a `Score`.
public enum MSCXParser {
    /// Parse uncompressed `.mscx` XML bytes into an in-memory `Score`.
    /// Throws `SheetMusicError.invalidXML` for ill-formed XML and
    /// `SheetMusicError.malformedScore` for missing required elements.
    ///
    /// Non-fatal anomalies (e.g. unknown embellishment subtypes) are
    /// dropped silently. Use `parseWithDiagnostics(_:)` to receive them.
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        return try Score.decode(root)
    }

    /// Read `.mscx` XML from a file URL and parse into a `Score`.
    /// I/O failures are wrapped in `SheetMusicError.ioError`.
    public static func parse(contentsOf url: URL) throws -> Score {
        let data = try readData(at: url)
        return try parse(data)
    }

    /// Parse `.mscx` XML bytes, returning the score together with any
    /// non-fatal anomalies observed during decoding (unknown
    /// embellishment subtypes, MS2 compat warnings, …). Throws the same
    /// errors as `parse(_:)` — structural problems still abort.
    public static func parseWithDiagnostics(
        _ data: Data,
    ) throws -> MSCXParseResult {
        let collector = MSCXDiagnosticCollector()
        let score = try MSCXParserContext.$collector.withValue(collector) {
            try parse(data)
        }
        return MSCXParseResult(score: score, diagnostics: collector.entries)
    }

    /// Read `.mscx` XML from a file URL and parse with diagnostics.
    public static func parseWithDiagnostics(
        contentsOf url: URL,
    ) throws -> MSCXParseResult {
        let data = try readData(at: url)
        return try parseWithDiagnostics(data)
    }

    private static func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
}
