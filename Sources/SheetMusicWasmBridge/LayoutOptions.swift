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
        )
    }
}
