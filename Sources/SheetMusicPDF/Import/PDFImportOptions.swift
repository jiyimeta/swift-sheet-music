import Foundation

/// Non-fatal recognition issues surfaced from `PDFImporter`.
///
/// `Sendable` because the callback that delivers it already is: a host that
/// parses off the main actor collects these on the parse's thread and reads
/// them back on its own.
public struct PDFImportDiagnostic: Sendable {
    public enum Severity: Sendable { case info, warning }
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
    /// Tier 4's acceptance threshold cannot be chosen without measuring it
    /// against Tier 1's known-correct answer. At the original placeholder
    /// threshold, with no per-font gate, it matched essentially every glyph
    /// outline — including Latin text and CJK lyrics — to some Bravura
    /// exemplar: on ギブス.pdf, 0 of 4254 glyphs were left `.unknown` and
    /// lyric recall collapsed to 0%. Both the measured threshold and the
    /// gate now exist, but flipping this default is its own decision, to be
    /// made on a measurement of unknown-font accuracy (last measured: 63.3%
    /// against a Bravura-only exemplar set — short of useful).
    public var enableShapeMatching = false
    /// TESTING ONLY, INTERNAL. Suppress Tier 1 (SMuFL codepoint)
    /// classification so the shape-matching tier can be measured against
    /// Tier 1's known-correct answer. Never set this in production; it
    /// degrades every SMuFL PDF.
    ///
    /// Not `public`: its only caller is the measurement harness, which
    /// already reaches internals through `@testable import SheetMusicPDF`.
    /// A public symbol cannot be withdrawn without a breaking change, and
    /// the package is past 1.0 — so a knob that exists to break the
    /// importer on purpose stays inside the module. Same for
    /// `anchorMusicGlyphsToPUARange` and `bypassMusicFontGateForTesting`
    /// below.
    var disableSMuFLCodepointTier = false
    /// TESTING ONLY, INTERNAL. Anchors the music/text routing decision in `emitShow`
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
    var anchorMusicGlyphsToPUARange = false
    /// TESTING ONLY, INTERNAL. Skips the per-font music-font gate
    /// (`GlyphClassifier.isLikelyMusicFont`) so `enableShapeMatching` behaves
    /// exactly as it did before that gate existed — Tier 4 answers for
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
    var bypassMusicFontGateForTesting = false
    /// TESTING ONLY, INTERNAL. Overrides `GlyphClassifier`'s default
    /// per-font music-font gate knobs (see its `default*` constants) for
    /// every `GlyphClassifier` this parse creates. Not `public` — reached
    /// only from within `SheetMusicPDF` or via `@testable import` — because
    /// these are instance configuration on an internal type, not a stable
    /// public knob. Exists so a test that must go through the real
    /// `PDFImporter.parse(pdfData:options:)` entry point (rather than
    /// constructing a `GlyphClassifier` directly) can loosen or tighten the
    /// gate without mutating shared process-global state — see
    /// `PDFImporterShapeMatchingGateTests`'
    /// `noGateAtPlaceholderThresholdReproducesTask12Collapse`.
    ///
    /// The literal defaults below MUST track `GlyphClassifier`'s
    /// `default*` constants — duplicated rather than referenced because
    /// `GlyphClassifier` is CoreText-backed and excluded from the Android
    /// build (see `Package.swift`), while this file (and the rest of
    /// `PDFImportOptions`) is not.
    var musicFontGateBound = 0.10
    var musicFontGateFraction = 0.5
    var shapeAcceptanceThreshold = 0.15
    public var diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)?

    /// A tile classifier for pages the vector path cannot read. `nil` — the
    /// default — means the importer behaves exactly as it always has: no
    /// rasterization, no detection, no new pass over the pages.
    ///
    /// Takes the tile classifier rather than a glyph detector because the
    /// detector's seam mentions importer internals; the importer builds
    /// `OMRGlyphDetector(classifier:)` from this.
    ///
    /// The PDFKit entry points act on it: `PDFImporter.parse(pdfData:)` /
    /// `parse(pdfURL:)` and their `parseWithGeometry` twins (whose side-car
    /// carries no rects for the pages read this way). `parseUsingSwiftReader`
    /// and the Android entry emit an `info` diagnostic saying they do not,
    /// rather than ignoring it silently.
    public var omrTileClassifier: (any OMRTileClassifier)?

    /// Resolution at which a page with no vector content is rasterized. The
    /// training corpus's DPI grid is 200/300/400, so 300 sits mid-distribution.
    ///
    /// Values below `PDFImporter.minimumRenderDPI` (72 — one pixel per point),
    /// and non-finite ones, are clamped with a `warning` diagnostic rather
    /// than silently rasterizing a 1x1 page.
    public var omrRenderDPI: Double = 300

    /// TESTING ONLY, INTERNAL. Substitutes the whole glyph-detection stage so the
    /// harness can replay labels or precomputed detections through the product
    /// path. Takes precedence over `omrTileClassifier`. Not `public` for the same
    /// reason as `disableSMuFLCodepointTier`: a knob whose purpose is to bypass
    /// the real detector cannot be withdrawn once it is API.
    var omrDetector: (any OMRGlyphDetecting)?

    public init() {}
}
