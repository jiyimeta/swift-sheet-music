#if canImport(CoreGraphics)
    import CoreGraphics
#else
    // On non-Apple platforms (Android, Linux), swift-corelibs-foundation
    // provides CGFloat / CGPoint / CGSize via Foundation.
#endif
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension FrameImage {
    /// Encode as `<Image>`: `path`, then each value that differs from MS's default, then the preserved children.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [XMLTreeNode(name: "path", text: path)]
        if autoScale {
            children.append(XMLTreeNode(name: "autoScale", text: "1"))
        }
        if let size {
            children.append(XMLTreeNode(name: "size", attributes: [
                "w": FormatG.string(Double(size.width)),
                "h": FormatG.string(Double(size.height)),
            ]))
        }
        if !lockAspectRatio {
            children.append(XMLTreeNode(name: "lockAspectRatio", text: "0"))
        }
        if !sizeIsSpatium {
            children.append(XMLTreeNode(name: "sizeIsSpatium", text: "0"))
        }
        if let offsetSp {
            children.append(XMLTreeNode(name: "offset", attributes: [
                "x": FormatG.string(Double(offsetSp.x)),
                "y": FormatG.string(Double(offsetSp.y)),
            ]))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Image", children: children)
    }
}
