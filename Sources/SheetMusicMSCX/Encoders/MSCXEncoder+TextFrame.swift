#if canImport(CoreGraphics)
    import CoreGraphics
#else
    // On non-Apple platforms (Android, Linux), swift-corelibs-foundation
    // provides CGFloat via Foundation.
#endif
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// A numeric child, or nothing when the value is `nil` — the one writer the three box kinds share.
func boxChild(_ name: String, _ value: CGFloat?) -> XMLTreeNode? {
    value.map { XMLTreeNode(name: name, text: FormatG.string(Double($0))) }
}

/// `<topGap>` then `<bottomGap>`, each only when set.
func appendBoxGaps(top: CGFloat?, bottom: CGFloat?, to children: inout [XMLTreeNode]) {
    children.append(contentsOf: [boxChild("topGap", top), boxChild("bottomGap", bottom)].compactMap(\.self))
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
        children.append(contentsOf: entries.compactMap { name, value in
            value == 0 ? nil : boxChild(name, value)
        })
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
