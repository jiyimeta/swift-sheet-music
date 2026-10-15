#if canImport(CoreGraphics)
    import CoreGraphics
#elseif !os(WASI)
    // See `ScoreFrame.swift` for why this file may reach past `SheetMusicFoundation`.
    // swiftlint:disable:next no_foundation_umbrella
    import Foundation
#endif

/// Margins of a `<TBox>` in millimetres (`<leftMargin>` and friends; MS `box.cpp` `TextFrame` margins, default 0).
public struct FrameMargins: Sendable, Equatable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

/// A `<TBox>`: a frame between systems that holds a single text (MS `boxlayout.cpp:337-362`). It has no images — MS
/// lays out a TBox's text alone.
public struct TextFrame: Sendable, Equatable {
    public var text: FrameText?
    /// Gap above the frame in spatium; `nil` is MS's default of 7 sp (`box.cpp:255-258`).
    public var topGapSp: CGFloat?
    /// Gap below the frame in spatium; `nil` is MS's default of 7 sp.
    public var bottomGapSp: CGFloat?
    public var margins: FrameMargins
    /// Source children that the typed model does not represent.
    public var preservedMarkup: [PreservedXML]

    /// Whether the frame carries a page break (a `LayoutBreak` whose `subtype` is `page`). Computed from
    /// `preservedMarkup` so it cannot go stale when a host edits the bag.
    public var pageBreakAfter: Bool {
        preservedMarkup.hasPageBreak
    }

    public init(
        text: FrameText? = nil,
        topGapSp: CGFloat? = nil,
        bottomGapSp: CGFloat? = nil,
        margins: FrameMargins = FrameMargins(),
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.text = text
        self.topGapSp = topGapSp
        self.bottomGapSp = bottomGapSp
        self.margins = margins
        self.preservedMarkup = preservedMarkup
    }
}

/// An `<HBox>`: horizontal room between two measures. No images and no page break (a line break inside a system is
/// not modeled).
public struct HorizontalFrame: Sendable, Equatable {
    /// Width in spatium; `nil` is MS's default of 5 sp (`box.cpp:593-603`).
    public var widthSp: CGFloat?
    /// An HBox's left gap in spatium; `nil` is 0 (`box.cpp:71-74`).
    public var topGapSp: CGFloat?
    /// An HBox's right gap in spatium; `nil` is 0.
    public var bottomGapSp: CGFloat?
    /// Source children that the typed model does not represent.
    public var preservedMarkup: [PreservedXML]

    public init(
        widthSp: CGFloat? = nil,
        topGapSp: CGFloat? = nil,
        bottomGapSp: CGFloat? = nil,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.widthSp = widthSp
        self.topGapSp = topGapSp
        self.bottomGapSp = bottomGapSp
        self.preservedMarkup = preservedMarkup
    }
}

extension ScoreBlock {
    /// Return a copy without the source-only XML the block carries: the carrier's bag, the inline-markup bag of every
    /// `FrameText` it holds, and the bag of every `FrameImage` (VBox only).
    package func strippingPreservedMarkup() -> ScoreBlock {
        switch self {
        case var .verticalFrame(frame):
            frame.preservedMarkup = []
            for textIndex in frame.texts.indices {
                frame.texts[textIndex].preservedTextMarkup = nil
            }
            for imageIndex in frame.images.indices {
                frame.images[imageIndex].preservedMarkup = []
            }
            return .verticalFrame(frame)
        case var .textFrame(frame):
            frame.preservedMarkup = []
            frame.text?.preservedTextMarkup = nil
            return .textFrame(frame)
        case var .horizontalFrame(frame):
            frame.preservedMarkup = []
            return .horizontalFrame(frame)
        case var .opaqueFrame(frame):
            frame.preservedMarkup = []
            return .opaqueFrame(frame)
        }
    }
}
