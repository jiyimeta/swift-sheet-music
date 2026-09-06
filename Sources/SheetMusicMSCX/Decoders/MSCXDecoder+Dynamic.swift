import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Dynamic {
    private static let consumedDynamicChildren: Set = [
        "bold", "color", "face", "framePadding", "frameType", "italic", "size",
        "offset", "strike", "subtype", "underline", "velocity", "visible",
    ]

    static func decode(_ node: XMLTreeNode) throws -> Dynamic {
        let subtype = node.first("subtype")?.text ?? "mf"
        let velocity: Int
        if let vText = node.first("velocity")?.text, let v = Int(vText) {
            velocity = v
        } else {
            velocity = Dynamic.defaultVelocity(for: subtype)
        }
        var dynamic = Dynamic(
            subtype: subtype,
            velocity: velocity,
            properties: TextProperties.decode(node),
            preservedMarkup: node.preservedMarkup(consuming: consumedDynamicChildren),
        )
        dynamic.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return dynamic
    }
}
