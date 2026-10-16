#if canImport(CoreGraphics)
    import CoreGraphics
#else
    // On non-Apple platforms (Android, Linux), swift-corelibs-foundation
    // provides CGFloat / CGPoint via Foundation.
#endif
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ScoreFrame {
    /// Encode this frame as MuseScore's `<VBox>` element. Mirrors the
    /// shape `MSCXDecoder+ScoreFrame.decode(vbox:)` reads:
    /// `<height>`, the gaps and `<boxAutoSize>` when set, then the `<Text>` blocks and the `<Image>` children.
    func encodeAsVBox(
        options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(
                name: "height",
                text: FormatG.string(Double(heightSp)),
            ),
        ]
        appendBoxGaps(top: topGapSp, bottom: bottomGapSp, to: &children)
        if let autoSize {
            children.append(XMLTreeNode(name: "boxAutoSize", text: autoSize ? "1" : "0"))
        }
        for text in texts {
            children.append(text.encode(options: options))
        }
        for image in images {
            children.append(image.encode(options: options))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "VBox", children: children)
    }
}

extension FrameText {
    /// Encode a single `<Text>` block. Style is omitted only when
    /// `.other` since the decoder maps unknown / missing `<style>` to
    /// `.other`. The `<offset>` element carries `x` / `y` attributes
    /// in millimetres, matching the decoder's read path.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if style != .other {
            children.append(XMLTreeNode(
                name: "style", text: style.rawValue,
            ))
        } else if let otherStyleName {
            children.append(XMLTreeNode(name: "style", text: otherStyleName))
        }
        if let fontSize {
            children.append(XMLTreeNode(
                name: "size",
                text: FormatG.string(fontSize),
            ))
        }
        if let offsetMm {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": FormatG.string(Double(offsetMm.x)),
                    "y": FormatG.string(Double(offsetMm.y)),
                ],
            ))
        }
        if let align {
            children.append(XMLTreeNode(
                name: "align", text: align.mscxString,
            ))
        }
        children.append(encodeText(
            text,
            preservedTextMarkup: preservedTextMarkup,
            options: options,
        ))
        return XMLTreeNode(name: "Text", children: children)
    }
}
