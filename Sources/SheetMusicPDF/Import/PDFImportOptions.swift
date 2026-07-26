import Foundation

/// Non-fatal recognition issues surfaced from `PDFImporter`.
public struct PDFImportDiagnostic {
    public enum Severity { case info, warning }
    public let severity: Severity
    public let location: String // e.g. "page 3, system 2, measure 17"
    public let message: String
    public let context: String?

    public init(
        severity: Severity, location: String,
        message: String, context: String? = nil,
    ) {
        self.severity = severity
        self.location = location
        self.message = message
        self.context = context
    }
}

public struct PDFImportOptions {
    public var preserveBreaks = true
    public var useMetadataAsFallback = true
    /// Expand a collapsed "N-bar" multi-measure rest (the H-bar captioned
    /// with a count) back into its N constituent measures, so the imported
    /// score's measure count matches the uncollapsed source. Enabled by
    /// default; disable to keep each mm-rest as the single bar MuseScore drew.
    public var expandMultiMeasureRests = true
    /// Enable Tier 4 (outline shape matching) in the glyph classification
    /// cascade. **Default OFF.**
    ///
    /// Tier 4's acceptance threshold cannot be chosen without the measurement
    /// Task 13's ablation produces. Enabled at the placeholder threshold it
    /// matches essentially every glyph outline — including Latin text and CJK
    /// lyrics — to some Bravura exemplar: on ギブス.pdf, 0 of 4254 glyphs were
    /// left `.unknown` and lyric recall collapsed to 0%. It stays off until
    /// Task 14 has both a measured threshold and a per-font gate.
    public var enableShapeMatching = false
    public var diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?

    public init() {}
}
