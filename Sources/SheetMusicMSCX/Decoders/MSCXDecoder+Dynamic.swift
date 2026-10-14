import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Dynamic {
    private static let consumedDynamicChildren: Set = [
        "bold", "color", "face", "framePadding", "frameType", "italic", "size",
        "offset", "autoplace", "placement", "strike", "subtype", "underline", "velocity", "visible",
        "text", "play", "veloChangeSpeed", "voiceAssignment", "dynType",
    ]

    /// Decode one `<Dynamic>`. `<text>` is the dynamic's own text: MuseScore writes it only when it differs from the
    /// subtype's (`Dynamic::hasCustomText`, `dom/dynamic.h:98`), and whatever a file holds is kept, so it saves back
    /// as read. `<play>` and `<veloChangeSpeed>` are read as `TRead::read(Dynamic*)` reads them
    /// (`rw/read460/tread.cpp:769-792`); `<veloChange>` stays preserved.
    static func decode(_ node: XMLTreeNode) throws -> Dynamic {
        let subtype = node.first("subtype")?.text ?? "mf"
        let velocity: Int
        if let vText = node.first("velocity")?.text, let v = Int(vText) {
            velocity = v
        } else {
            velocity = Dynamic.defaultVelocity(for: subtype)
        }
        let textNode = node.first("text")
        let speed = node.first("veloChangeSpeed").flatMap { VelocityChangeSpeed(rawValue: $0.text) } ?? .normal
        var dynamic = Dynamic(
            subtype: subtype,
            velocity: velocity,
            properties: TextProperties.decode(node),
            preservedMarkup: node.preservedMarkup(consuming: consumedDynamicChildren),
            text: textNode.map(StaffText.plainText(of:)),
            preservedTextMarkup: textNode.flatMap(StaffText.preservedTextMarkup(of:)),
            playsBack: node.first("play").map { $0.text != "0" } ?? true,
            velocityChangeSpeed: speed,
            voiceAssignment: VoiceAssignment.decode(node),
        )
        dynamic.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return dynamic
    }
}
