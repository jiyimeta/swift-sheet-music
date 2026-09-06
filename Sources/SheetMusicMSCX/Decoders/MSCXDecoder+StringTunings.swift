import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StringTunings {
    /// Every direct `<StringTunings>` child this decoder reads. `<style>`,
    /// `<placement>`, font overrides, and `StaffTextBase` channel and swing
    /// properties are not modeled and become preserved markup.
    ///
    /// `color` and `visible` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads them.
    ///
    /// `offset` is deliberately NOT here yet. A consumed tag is excluded from
    /// preserved markup, so listing one the decoder does not actually read
    /// drops it: `<offset>` would land in neither the model nor the bag. Add
    /// it in the same commit that teaches `ElementProperties` to read it —
    /// the parity doc's §7.2 work — and not before.
    private static let consumedChildren: Set = [
        "preset", "visibleStrings", "StringData", "text", "color", "visible",
    ]

    /// Decode one `<StringTunings>`.
    ///
    /// Nothing throws: string tunings are an embellishment under the parser
    /// policy, so malformed list members are skipped rather than failing the
    /// score. C++: `TRead::read(StringTunings*, ...)`
    /// (`rw/read460/tread.cpp:4217`).
    static func decode(_ node: XMLTreeNode) -> StringTunings {
        let visibleStrings = node.first("visibleStrings").map { child in
            child.text.split(separator: ",").compactMap { Int($0) }
        } ?? []
        var tunings = StringTunings(
            preset: node.first("preset")?.text ?? "",
            visibleStrings: visibleStrings,
            stringData: node.first("StringData").map(StringData.decode(_:)),
            text: node.first("text").map(StaffText.plainText(of:)) ?? "",
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        tunings.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return tunings
    }
}
