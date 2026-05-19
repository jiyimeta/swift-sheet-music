import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension TextProperties {
    /// Append the per-element font / frame children (`<face>`,
    /// `<size>`, `<bold>`, …) to the parent's child array. Inverse of
    /// `TextProperties.decode(_:)` — only fields that are non-nil are
    /// emitted, so the absence of an element still means "inherit"
    /// after re-parsing.
    func appendXML(to children: inout [XMLTreeNode]) {
        if let face {
            children.append(XMLTreeNode(name: "face", text: face))
        }
        if let size {
            children.append(XMLTreeNode(name: "size", text: formatDouble(size)))
        }
        if let style {
            // Each flag is independent; emit `1` for set, `0` for
            // unset. The decoder treats *any* present flag as "an
            // opinion has been expressed", so once one flag is
            // emitted we emit all four for symmetric round-trip.
            children.append(XMLTreeNode(
                name: "bold",
                text: style.contains(.bold) ? "1" : "0",
            ))
            children.append(XMLTreeNode(
                name: "italic",
                text: style.contains(.italic) ? "1" : "0",
            ))
            children.append(XMLTreeNode(
                name: "underline",
                text: style.contains(.underline) ? "1" : "0",
            ))
            children.append(XMLTreeNode(
                name: "strike",
                text: style.contains(.strike) ? "1" : "0",
            ))
        }
        if let frameType {
            children.append(XMLTreeNode(
                name: "frameType", text: String(encodeFrame(frameType)),
            ))
        }
        if let framePadding {
            children.append(XMLTreeNode(
                name: "framePadding", text: formatDouble(framePadding),
            ))
        }
    }
}

/// Inverse of `decodeFrame(_:)` — `TextFrameType` → mscx `<frameType>` int.
/// Mirrors MuseScore's `FrameType` enum (`engraving/dom/textbase.h`):
/// `NO_FRAME=0, SQUARE=1, CIRCLE=2`.
private func encodeFrame(_ frame: TextFrameType) -> Int {
    switch frame {
    case .none: 0
    case .rectangle: 1
    case .circle: 2
    }
}

/// Stable Double → String. Avoids `Double.description`'s scientific
/// notation for very small/large values and trailing-zero churn.
func formatDouble(_ value: Double) -> String {
    if value == value.rounded() {
        return String(Int(value))
    }
    return String(value)
}
