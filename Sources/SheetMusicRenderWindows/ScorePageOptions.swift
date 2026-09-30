import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

/// How `ScorePages.compute` lays a score out and pages it: the display options a portable host passes, typed.
///
/// One property per field of the options the Android bridge carries (the web bridge carries a subset of them), with
/// the same meaning and the same defaults, so a Windows host lays a score out exactly as they do. Where those options
/// say "no opinion" (the engine's own default, or one derived from another option) the property is optional, and `nil`
/// is that: set it only to override.
public struct ScorePageOptions: Sendable, Equatable {
    /// The page model.
    public enum Mode: Sendable, Hashable, CaseIterable {
        /// One continuous page wrapped to the page width, the title block included, as tall as the music.
        case vertical
        /// One single-system page at the score's natural width, no title block.
        case horizontal
        /// Wrapped like `.vertical`, then split into pages of the page height.
        case page
    }

    /// Engraving distances, in staff spaces except `systemStretch` (a unitless ratio) — `EngravingSpacing`'s fields,
    /// each optional: `nil` keeps the engine's own value (`EngravingSpacing.standard`). The margins are
    /// `EngravingMargins`' four.
    public struct Spacing: Sendable, Equatable {
        public var minNoteDistance: Double?
        public var spacePerQuarter: Double?
        public var systemStretch: Double?
        public var marginTop: Double?
        public var marginLeading: Double?
        public var marginBottom: Double?
        public var marginTrailing: Double?
        public var firstSystemIndent: Double?
        public var continuationSystemIndent: Double?
        public var minStaffGap: Double?
        public var systemVerticalPadding: Double?

        public init(
            minNoteDistance: Double? = nil,
            spacePerQuarter: Double? = nil,
            systemStretch: Double? = nil,
            marginTop: Double? = nil,
            marginLeading: Double? = nil,
            marginBottom: Double? = nil,
            marginTrailing: Double? = nil,
            firstSystemIndent: Double? = nil,
            continuationSystemIndent: Double? = nil,
            minStaffGap: Double? = nil,
            systemVerticalPadding: Double? = nil,
        ) {
            self.minNoteDistance = minNoteDistance
            self.spacePerQuarter = spacePerQuarter
            self.systemStretch = systemStretch
            self.marginTop = marginTop
            self.marginLeading = marginLeading
            self.marginBottom = marginBottom
            self.marginTrailing = marginTrailing
            self.firstSystemIndent = firstSystemIndent
            self.continuationSystemIndent = continuationSystemIndent
            self.minStaffGap = minStaffGap
            self.systemVerticalPadding = systemVerticalPadding
        }
    }

    public var mode: Mode
    /// Height of one five-line staff, in points.
    public var staffSize: Double
    /// Whether runs of rest measures collapse into one multi-measure rest (of at least `multiMeasureRestMinimum`).
    public var collapsesMultiMeasureRests: Bool
    /// MuseScore's "Show Invisible": invisible elements are laid out and drawn gray rather than dropped.
    public var showsInvisibleElements: Bool
    /// Staves left out of the layout, addressed in the score passed to `compute`.
    public var hiddenStaves: Set<StaffAddress>
    /// Opening-clef overrides, as `Score.applying(clefOverrides:)` takes them: the raw clef type by staff, addressed
    /// in the score passed to `compute` (the overrides are applied before `hiddenStaves` are dropped).
    public var clefOverrides: [StaffAddress: String]
    /// Whole-score notation transposition in semitones, clamped to −12…+12. The notation only: transposed playback is
    /// the playback engine's `setTranspose(semitones:)`.
    public var transposeSemitones: Int
    /// Whether sung text is engraved at all. Hiding it removes the whole row (hyphens and melisma lines included) and
    /// makes the layout shorter; `showsInvisibleElements` does not bring it back.
    public var showsLyrics: Bool
    /// How authored `<LayoutBreak>` markup is consumed; `nil` is the engine's default (`.honor`).
    public var breakPolicy: LayoutBreakPolicy?
    /// The fewest consecutive rest measures that collapse, when `collapsesMultiMeasureRests` is on; below 2 reads as 2.
    public var multiMeasureRestMinimum: Int
    /// How often a measure number is engraved; a system head always carries one.
    public var measureNumbers: MeasureNumberPolicy
    /// Vertical gap between systems, in points; `nil` (or a value ≤ 0) derives it from the staff: `staffSize × 1.25`.
    public var systemGapPoints: Double?
    /// Whether the title block is laid out; `nil` decides from the mode (off in `.horizontal`, on otherwise).
    public var includesTitleFrame: Bool?
    /// Which break-indicator badges the layout asks for. No effect on the pages yet: the badges are an overlay the
    /// Apple renderer draws over the score, not part of the draw program.
    public var breakIndicatorVisibility: BreakIndicatorVisibility
    /// Scale of grace-note glyphs; `nil` (or a value ≤ 0) keeps the engine's default.
    public var graceNoteMag: Double?
    /// Scale of small and cue noteheads; `nil` (or a value ≤ 0) keeps the engine's default.
    public var smallNoteMag: Double?
    public var spacing: Spacing

    public init(
        mode: Mode = .vertical,
        staffSize: Double = 28,
        collapsesMultiMeasureRests: Bool = false,
        showsInvisibleElements: Bool = false,
        hiddenStaves: Set<StaffAddress> = [],
        clefOverrides: [StaffAddress: String] = [:],
        transposeSemitones: Int = 0,
        showsLyrics: Bool = true,
        breakPolicy: LayoutBreakPolicy? = nil,
        multiMeasureRestMinimum: Int = 2,
        measureNumbers: MeasureNumberPolicy = .systemStart,
        systemGapPoints: Double? = nil,
        includesTitleFrame: Bool? = nil,
        breakIndicatorVisibility: BreakIndicatorVisibility = .none,
        graceNoteMag: Double? = nil,
        smallNoteMag: Double? = nil,
        spacing: Spacing = Spacing(),
    ) {
        self.mode = mode
        self.staffSize = staffSize
        self.collapsesMultiMeasureRests = collapsesMultiMeasureRests
        self.showsInvisibleElements = showsInvisibleElements
        self.hiddenStaves = hiddenStaves
        self.clefOverrides = clefOverrides
        self.transposeSemitones = transposeSemitones
        self.showsLyrics = showsLyrics
        self.breakPolicy = breakPolicy
        self.multiMeasureRestMinimum = multiMeasureRestMinimum
        self.measureNumbers = measureNumbers
        self.systemGapPoints = systemGapPoints
        self.includesTitleFrame = includesTitleFrame
        self.breakIndicatorVisibility = breakIndicatorVisibility
        self.graceNoteMag = graceNoteMag
        self.smallNoteMag = smallNoteMag
        self.spacing = spacing
    }

    /// Vertical mode at a 28 pt staff with every other option at its default: what the portable bridges lay out with
    /// when a host passes no options.
    public static var `default`: ScorePageOptions {
        ScorePageOptions()
    }
}

// MARK: - The wire

extension ScorePageOptions {
    /// These options as the bridge reads them. Staves and clef overrides go in address order, so equal options give
    /// equal wires.
    package func wire() -> LayoutOptionsWire {
        let hidden: [HiddenStaffWire] = hiddenStaves.sorted().map { address in
            HiddenStaffWire(
                partIndex: Int32(clamping: address.partIndex),
                staffIndexInPart: Int32(clamping: address.staffIndexInPart),
            )
        }
        let clefs: [ClefOverrideWire] = clefOverrides.sorted { $0.key < $1.key }.map { address, rawType in
            ClefOverrideWire(
                partIndex: Int32(clamping: address.partIndex),
                staffIndexInPart: Int32(clamping: address.staffIndexInPart),
                rawType: rawType,
            )
        }
        return LayoutOptionsWire(
            layoutMode: mode.wire.rawValue,
            staffSize: staffSize,
            collapseMultiMeasureRests: collapsesMultiMeasureRests ? 1 : 0,
            showsInvisibleElements: showsInvisibleElements ? 1 : 0,
            hiddenStaves: hidden,
            clefOverrides: clefs,
            transposeSemitones: Int32(clamping: transposeSemitones),
            showsLyrics: showsLyrics ? 1 : 0,
            breakPolicyRaw: breakPolicy.map(Self.breakPolicyRaw) ?? 0,
            multiMeasureRestMinimum: Int32(clamping: multiMeasureRestMinimum),
            measureNumberInterval: Self.measureNumberInterval(measureNumbers),
            systemGapPoints: systemGapPoints ?? 0,
            includeTitleFrameRaw: includesTitleFrame.map { $0 ? UInt8(1) : 0 } ?? 2,
            breakIndicatorVisibilityRaw: Self.breakIndicatorVisibilityRaw(breakIndicatorVisibility),
            graceNoteMag: graceNoteMag ?? 0,
            smallNoteMag: smallNoteMag ?? 0,
            spacing: spacing.wire(),
        )
    }

    /// `LayoutOptionsWire.breakPolicy` read backwards; `0`, "no opinion", is `nil`.
    private static func breakPolicyRaw(_ policy: LayoutBreakPolicy) -> UInt8 {
        switch policy {
        case .honor: 1
        case .ignoreSystemBreaks: 2
        case .ignoreAll: 3
        }
    }

    /// `LayoutOptionsWire.measureNumberPolicy` read backwards. An interval below 1 is 1, as the policy reads it.
    private static func measureNumberInterval(_ policy: MeasureNumberPolicy) -> Int32 {
        switch policy {
        case .systemStart: 0
        case let .interval(every): Int32(clamping: max(1, every))
        }
    }

    /// `LayoutOptionsWire.breakIndicatorVisibility` read backwards.
    private static func breakIndicatorVisibilityRaw(_ visibility: BreakIndicatorVisibility) -> UInt8 {
        switch visibility {
        case .none: 0
        case .pageOnly: 1
        case .all: 2
        }
    }
}

extension ScorePageOptions.Mode {
    var wire: LayoutOptionsWire.Mode {
        switch self {
        case .vertical: .vertical
        case .horizontal: .horizontal
        case .page: .page
        }
    }
}

extension ScorePageOptions.Spacing {
    /// `nil` when no field is set: the wire's own "engine defaults", which an all-`nil` struct means as well.
    func wire() -> EngravingSpacingWire? {
        guard self != Self() else { return nil }
        return EngravingSpacingWire(
            minNoteDistance: minNoteDistance,
            spacePerQuarter: spacePerQuarter,
            systemStretch: systemStretch,
            marginTop: marginTop,
            marginLeading: marginLeading,
            marginBottom: marginBottom,
            marginTrailing: marginTrailing,
            firstSystemIndent: firstSystemIndent,
            continuationSystemIndent: continuationSystemIndent,
            minStaffGap: minStaffGap,
            systemVerticalPadding: systemVerticalPadding,
        )
    }
}
