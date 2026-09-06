import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Fingering {
    /// Every direct `<Fingering>` child this decoder reads. Per-element font
    /// overrides are not modeled and become preserved markup. The base
    /// `<offset>` and `<placement>` are owned by `ElementProperties`.
    ///
    /// `color` is consumed because `ElementProperties(decodingMSCXChildrenOf:)`
    /// reads it, the same arrangement every other decoder here has.
    private static let consumedChildren: Set = [
        "style", "text", "color", "offset", "placement", "visible",
    ]

    /// The `<Fingering>` children of a `<Note>`, in document order.
    ///
    /// A note carrying both a left-hand fingering and a string number is
    /// ordinary guitar notation, so several are expected and the order they
    /// were written in is kept.
    static func decodeAll(inNote node: XMLTreeNode) -> [Fingering] {
        node.all("Fingering").map(decode)
    }

    /// Decode one `<Fingering>`.
    ///
    /// Nothing throws: a fingering is an embellishment under the parser policy,
    /// and an empty one degrades to empty text rather than failing the score.
    /// C++: `TWrite::write(const Fingering*, …)` writes it as a bare `TextBase`
    /// (`rw/write/twrite.cpp:1456`), so `<style>` and `<text>` are all there is
    /// to read.
    static func decode(_ node: XMLTreeNode) -> Fingering {
        var fingering = Fingering(
            text: node.first("text").map(StaffText.plainText(of:)) ?? "",
            role: node.first("style").map { Role(mscxToken: $0.text) } ?? .fingering,
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        fingering.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return fingering
    }
}
