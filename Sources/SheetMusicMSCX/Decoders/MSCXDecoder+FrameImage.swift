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

extension FrameImage {
    private static let consumedChildren: Set = [
        "path", "autoScale", "size", "lockAspectRatio", "sizeIsSpatium", "offset",
    ]

    /// Parse an `<Image>` of a `<VBox>`. `size` is `w` / `h` and `offset` is `x` / `y` (spatium, MS
    /// `tread.cpp:501-505`); anything else (`z`, `visible`, `linkPath`, …) stays preserved.
    static func decode(_ node: XMLTreeNode) -> FrameImage {
        FrameImage(
            path: node.first("path")?.text ?? "",
            size: pair(node.first("size"), "w", "h").map { CGSize(width: $0.x, height: $0.y) },
            sizeIsSpatium: flag(node, "sizeIsSpatium", default: true),
            autoScale: flag(node, "autoScale", default: false),
            lockAspectRatio: flag(node, "lockAspectRatio", default: true),
            offsetSp: pair(node.first("offset"), "x", "y").map { CGPoint(x: $0.x, y: $0.y) },
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
    }

    private static func flag(_ node: XMLTreeNode, _ name: String, default fallback: Bool) -> Bool {
        guard let raw = node.first(name)?.text else { return fallback }
        return raw == "1" || raw == "true"
    }

    private static func pair(_ node: XMLTreeNode?, _ first: String, _ second: String) -> (x: CGFloat, y: CGFloat)? {
        guard let node,
              let firstRaw = node.attributes[first], let secondRaw = node.attributes[second],
              let firstValue = Double(firstRaw), let secondValue = Double(secondRaw)
        else { return nil }
        return (CGFloat(firstValue), CGFloat(secondValue))
    }
}
