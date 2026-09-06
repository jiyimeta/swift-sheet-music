import SheetMusicCore
import SheetMusicFoundation
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
        try parse(data, styleFileData: nil)
    }

    /// `parse(_:)` with the bytes of a container's `score_style.mss`
    /// supplied as the base style the score's own inline `<Style>`
    /// overrides. `MSCZReader` is the only caller that has one; plain
    /// `.mscx` input goes through `parse(_:)`.
    static func parse(
        _ data: Data, styleFileData: Data?,
    ) throws -> Score {
        let root = try XMLTreeParser.parse(
            data,
            preservingMixedContentIn: ["text"],
        )
        return try Score.decode(
            root, styleFileStyle: styleFileStyle(styleFileData),
        )
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
        try parseWithDiagnostics(data, styleFileData: nil)
    }

    /// `parseWithDiagnostics(_:)` with a container style file — see
    /// `parse(_:styleFileData:)`.
    static func parseWithDiagnostics(
        _ data: Data, styleFileData: Data?,
    ) throws -> MSCXParseResult {
        let collector = MSCXDiagnosticCollector()
        let score = try MSCXParserContext.$collector.withValue(collector) {
            try parse(data, styleFileData: styleFileData)
        }
        return MSCXParseResult(score: score, diagnostics: collector.entries)
    }

    /// Decode the `<Style>` element out of a `score_style.mss`
    /// document. A style file that will not parse — or whose shape is
    /// not `<museScore><Style>` — is reported and skipped rather than
    /// failing the score: the score body is intact and readable, and
    /// falling back to MuseScore's defaults is what happened before
    /// this reader looked at the file at all. It is reported because
    /// the fallback is silently wrong for the score (a score-level
    /// swing, a non-default staff size), which is exactly what an
    /// unannounced drop hides.
    private static func styleFileStyle(_ data: Data?) -> XMLTreeNode? {
        guard let data else { return nil }
        let root: XMLTreeNode
        do {
            root = try XMLTreeParser.parse(data)
        } catch {
            mscxDecoderWarn(
                code: "mscz.styleFile.unreadable",
                message: "score_style.mss did not parse as XML (\(error)); "
                    + "falling back to MuseScore's default style",
                location: "score_style.mss",
            )
            return nil
        }
        guard let style = ScoreStyle.styleNode(inStyleFile: root) else {
            mscxDecoderWarn(
                code: "mscz.styleFile.noStyleElement",
                message: "score_style.mss has no <museScore><Style>; "
                    + "falling back to MuseScore's default style",
                location: "score_style.mss",
            )
            return nil
        }
        return style
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
