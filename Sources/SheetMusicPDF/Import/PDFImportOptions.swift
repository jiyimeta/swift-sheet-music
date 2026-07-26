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
    /// TESTING ONLY. Suppress Tier 1 (SMuFL codepoint) classification so the
    /// shape-matching tier can be measured against Tier 1's known-correct
    /// answer. Never set this in production; it degrades every SMuFL PDF.
    public var disableSMuFLCodepointTier = false
    /// TESTING ONLY. Anchors the music/text routing decision in `emitShow`
    /// to whether the raw decoded codepoint falls in the SMuFL PUA range,
    /// ignoring which (if any) tier supplied the glyph's `SMuFLSemantic`.
    ///
    /// Exists so the Tier-1 ablation (toggling `disableSMuFLCodepointTier`)
    /// promotes the IDENTICAL set of codepoints to `ClassifiedGlyph` in both
    /// the truth and probe runs — only the assigned semantic may differ,
    /// making `truth.count == probe.count` hold by construction. Without
    /// this, Tier 4 (with Tier 1 disabled) also shape-matches non-music
    /// glyph outlines — lyric / title text from an unrelated embedded font
    /// — and wrongly promotes them into the music stream, desynchronizing
    /// any positional comparison against Tier 1's answer. A no-op whenever
    /// Tier 1 is enabled (Tier 1 only ever answers PUA-range codepoints), so
    /// this only ever changes behavior in combination with
    /// `disableSMuFLCodepointTier`. Never set this in production.
    public var anchorMusicGlyphsToPUARange = false
    /// TESTING ONLY. Skips the per-font music-font gate
    /// (`GlyphClassifier.isLikelyMusicFont`) so `enableShapeMatching` behaves
    /// exactly as it did before Task 14 added that gate — Tier 4 answers for
    /// every embedded font's glyphs, not just the ones the gate accepts.
    ///
    /// Exists so the Tier-4 ablation (`tier4Ablation`) keeps measuring Tier
    /// 4's raw per-glyph classification accuracy against Tier 1's
    /// known-correct answer, independent of font-level eligibility — the
    /// ablation already anchors to the PUA range (see
    /// `anchorMusicGlyphsToPUARange`), so it doesn't need the gate for
    /// correctness, and letting the gate filter individual font resources
    /// mid-ablation (measured: it wrongly declines a real 3-glyph "Bravura"
    /// resource in ロビンソン.pdf — too small a sample to pass the fraction
    /// test) would entangle two different measurements. The gate is a
    /// PRODUCTION safeguard; this flag keeps it out of that measurement.
    /// Never set this in production.
    public var bypassMusicFontGateForTesting = false
    public var diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?

    public init() {}
}
