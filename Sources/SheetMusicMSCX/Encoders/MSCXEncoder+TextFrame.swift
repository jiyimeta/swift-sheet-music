#if canImport(CoreGraphics)
    import CoreGraphics
#elseif !os(WASI)
    // This file names `CGFloat`, which Android, Windows and Linux take from swift-corelibs-foundation's umbrella. See
    // `MSCXDecoder+ScoreFrame.swift` for why this file may reach past `SheetMusicFoundation`; WASI takes
    // `SheetMusicCore`'s own type.
    // swiftlint:disable:next no_foundation_umbrella
    import Foundation
#endif
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// A numeric child, or nothing when the value is `nil` — the one writer the three box kinds share.
func boxChild(_ name: String, _ value: CGFloat?) -> XMLTreeNode? {
    guard let value else { return nil }
    return XMLTreeNode(name: name, text: FormatG.string(Double(value)))
}

/// `<topGap>` then `<bottomGap>`, each only when set.
func appendBoxGaps(top: CGFloat?, bottom: CGFloat?, to children: inout [XMLTreeNode]) {
    if let topNode = boxChild("topGap", top) {
        children.append(topNode)
    }
    if let bottomNode = boxChild("bottomGap", bottom) {
        children.append(bottomNode)
    }
}

extension TextFrame {
    /// Encode as MuseScore's `<TBox>`: gaps, the margins that differ from 0, the text, then the preserved children.
    func encodeAsTBox(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        appendBoxGaps(top: topGapSp, bottom: bottomGapSp, to: &children)
        let entries: [(String, CGFloat)] = [
            ("leftMargin", margins.left), ("rightMargin", margins.right),
            ("topMargin", margins.top), ("bottomMargin", margins.bottom),
        ]
        for entry in entries where entry.1 != 0 {
            if let child = boxChild(entry.0, entry.1) {
                children.append(child)
            }
        }
        if let text {
            children.append(text.encode(options: options))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "TBox", children: children)
    }
}

extension HorizontalFrame {
    /// Encode as MuseScore's `<HBox>`: width, the two gaps, then the preserved children.
    func encodeAsHBox(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let width = boxChild("width", widthSp) {
            children.append(width)
        }
        appendBoxGaps(top: topGapSp, bottom: bottomGapSp, to: &children)
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "HBox", children: children)
    }
}
