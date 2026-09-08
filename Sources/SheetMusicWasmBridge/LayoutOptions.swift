import JavaScriptKit
import SheetMusicBridgeCore

/// Android: `HiddenStaffWire`.
@JS public struct HiddenStaff {
    public var partIndex: Int
    public var staffIndexInPart: Int

    public init(partIndex: Int, staffIndexInPart: Int) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
    }
}

/// Android: `ClefOverrideWire`. `clef` is the raw clef type string.
@JS public struct ClefOverride {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var clef: String

    public init(partIndex: Int, staffIndexInPart: Int, clef: String) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.clef = clef
    }
}

/// Android: `EngravingSpacingWire`. Negative values, including `-1`, mean
/// unspecified and use the engine default. wasm uses this sentinel because
/// BridgeJS support for optional nested fields is unconfirmed, while the
/// TypeScript resolver supplies every field anyway.
@JS public struct EngravingSpacingOptions {
    public var minNoteDistance: Double
    public var spacePerQuarter: Double
    public var systemStretch: Double
    public var marginTop: Double
    public var marginLeading: Double
    public var marginBottom: Double
    public var marginTrailing: Double
    public var firstSystemIndent: Double
    public var continuationSystemIndent: Double
    public var minStaffGap: Double
    public var systemVerticalPadding: Double

    public init(
        minNoteDistance: Double,
        spacePerQuarter: Double,
        systemStretch: Double,
        marginTop: Double,
        marginLeading: Double,
        marginBottom: Double,
        marginTrailing: Double,
        firstSystemIndent: Double,
        continuationSystemIndent: Double,
        minStaffGap: Double,
        systemVerticalPadding: Double,
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

extension EngravingSpacingOptions {
    /// Every field unspecified — the engine's own defaults apply.
    ///
    /// Lives in an extension rather than as a member so `@JS` does not try
    /// to export it: JS callers build the object literally, and the
    /// TypeScript resolver already fills every field.
    ///
    /// Computed rather than a `static let` because `@JS` does not add a
    /// `Sendable` conformance, and stored global state of a non-`Sendable`
    /// type is a concurrency-safety error.
    public static var unspecified: EngravingSpacingOptions {
        EngravingSpacingOptions(
            minNoteDistance: -1,
            spacePerQuarter: -1,
            systemStretch: -1,
            marginTop: -1,
            marginLeading: -1,
            marginBottom: -1,
            marginTrailing: -1,
            firstSystemIndent: -1,
            continuationSystemIndent: -1,
            minStaffGap: -1,
            systemVerticalPadding: -1,
        )
    }
}

/// Android: `LayoutOptionsWire`.
@JS public struct LayoutOptions {
    /// 0 = vertical, 1 = horizontal, 2 = page.
    public var layoutMode: Int
    public var staffSize: Double
    public var honorLayoutBreaks: Bool
    public var collapseMultiMeasureRests: Bool
    public var showsInvisibleElements: Bool
    public var showsLyrics: Bool
    /// Clamped to -12...+12 by `LayoutOptionsWire.transposeDelta`.
    public var transposeSemitones: Int
    public var hiddenStaves: [HiddenStaff]
    public var clefOverrides: [ClefOverride]
    public var spacing: EngravingSpacingOptions

    public init(
        layoutMode: Int,
        staffSize: Double,
        honorLayoutBreaks: Bool,
        collapseMultiMeasureRests: Bool,
        showsInvisibleElements: Bool,
        showsLyrics: Bool,
        transposeSemitones: Int,
        hiddenStaves: [HiddenStaff],
        clefOverrides: [ClefOverride],
        spacing: EngravingSpacingOptions,
    ) {
        self.layoutMode = layoutMode
        self.staffSize = staffSize
        self.honorLayoutBreaks = honorLayoutBreaks
        self.collapseMultiMeasureRests = collapseMultiMeasureRests
        self.showsInvisibleElements = showsInvisibleElements
        self.showsLyrics = showsLyrics
        self.transposeSemitones = transposeSemitones
        self.hiddenStaves = hiddenStaves
        self.clefOverrides = clefOverrides
        self.spacing = spacing
    }
}

extension LayoutOptions {
    var wire: LayoutOptionsWire {
        LayoutOptionsWire(
            layoutMode: UInt8(clamping: layoutMode),
            staffSize: staffSize,
            honorLayoutBreaks: honorLayoutBreaks ? 1 : 0,
            collapseMultiMeasureRests: collapseMultiMeasureRests ? 1 : 0,
            showsInvisibleElements: showsInvisibleElements ? 1 : 0,
            hiddenStaves: hiddenStaves.map {
                HiddenStaffWire(
                    partIndex: Int32($0.partIndex),
                    staffIndexInPart: Int32($0.staffIndexInPart),
                )
            },
            clefOverrides: clefOverrides.map {
                ClefOverrideWire(
                    partIndex: Int32($0.partIndex),
                    staffIndexInPart: Int32($0.staffIndexInPart),
                    rawType: $0.clef,
                )
            },
            transposeSemitones: Int32(transposeSemitones),
            showsLyrics: showsLyrics ? 1 : 0,
            spacing: EngravingSpacingWire(
                minNoteDistance: spacing.minNoteDistance < 0 ? nil : spacing.minNoteDistance,
                spacePerQuarter: spacing.spacePerQuarter < 0 ? nil : spacing.spacePerQuarter,
                systemStretch: spacing.systemStretch < 0 ? nil : spacing.systemStretch,
                marginTop: spacing.marginTop < 0 ? nil : spacing.marginTop,
                marginLeading: spacing.marginLeading < 0 ? nil : spacing.marginLeading,
                marginBottom: spacing.marginBottom < 0 ? nil : spacing.marginBottom,
                marginTrailing: spacing.marginTrailing < 0 ? nil : spacing.marginTrailing,
                firstSystemIndent: spacing.firstSystemIndent < 0 ? nil : spacing.firstSystemIndent,
                continuationSystemIndent: spacing.continuationSystemIndent < 0
                    ? nil : spacing.continuationSystemIndent,
                minStaffGap: spacing.minStaffGap < 0 ? nil : spacing.minStaffGap,
                systemVerticalPadding: spacing.systemVerticalPadding < 0
                    ? nil : spacing.systemVerticalPadding,
            ),
        )
    }
}
