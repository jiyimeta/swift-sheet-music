#if canImport(CoreGraphics)
    import CoreGraphics
#elseif !os(WASI)
    // See `MSCXDecoder+ScoreFrame.swift` for why this file may reach past `SheetMusicFoundation`.
    // swiftlint:disable:next no_foundation_umbrella
    import Foundation
#endif
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// What `<VBox>`, `<TBox>` and `<HBox>` share when they are read: the `<topGap>` / `<bottomGap>` pair and the children
/// no decoder of the box kind consumes. One reader serves the three kinds.
struct BoxChildren {
    let node: XMLTreeNode
    var topGapSp: CGFloat?
    var bottomGapSp: CGFloat?
    var preservedMarkup: [PreservedXML]

    /// `consumed` lists the children the box kind reads besides the gaps.
    init(_ node: XMLTreeNode, consuming consumed: Set<String>) {
        self.node = node
        topGapSp = node.boxNumber("topGap")
        bottomGapSp = node.boxNumber("bottomGap")
        preservedMarkup = node.preservedMarkup(consuming: consumed.union(["topGap", "bottomGap"]))
    }

    func number(_ name: String) -> CGFloat? {
        node.boxNumber(name)
    }
}

extension XMLTreeNode {
    /// A numeric child's value, `nil` when absent or malformed.
    func boxNumber(_ name: String) -> CGFloat? {
        first(name)?.text.flatMap { Double($0) }.map { CGFloat($0) }
    }
}

extension TextFrame {
    private static let consumedChildren: Set = [
        "Text", "leftMargin", "rightMargin", "topMargin", "bottomMargin",
    ]

    /// Parse a `<TBox>`: its single `<Text>`, gaps and margins (mm). Everything else — including an `<Image>`, which MS
    /// never lays out under a TBox — stays preserved.
    static func decode(tbox node: XMLTreeNode) -> TextFrame {
        let box = BoxChildren(node, consuming: consumedChildren)
        return TextFrame(
            text: node.first("Text").flatMap(FrameText.decode(_:)),
            topGapSp: box.topGapSp,
            bottomGapSp: box.bottomGapSp,
            margins: FrameMargins(
                left: box.number("leftMargin") ?? 0,
                right: box.number("rightMargin") ?? 0,
                top: box.number("topMargin") ?? 0,
                bottom: box.number("bottomMargin") ?? 0,
            ),
            preservedMarkup: box.preservedMarkup,
        )
    }
}

extension HorizontalFrame {
    /// Parse an `<HBox>`: its width and the left / right gap (`<topGap>` / `<bottomGap>`).
    static func decode(hbox node: XMLTreeNode) -> HorizontalFrame {
        let box = BoxChildren(node, consuming: ["width"])
        return HorizontalFrame(
            widthSp: box.number("width"),
            topGapSp: box.topGapSp,
            bottomGapSp: box.bottomGapSp,
            preservedMarkup: box.preservedMarkup,
        )
    }
}
