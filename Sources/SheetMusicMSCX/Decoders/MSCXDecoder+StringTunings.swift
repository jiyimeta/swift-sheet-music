import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StringTunings {
    /// Every direct `<StringTunings>` child this decoder reads. `<style>`, font
    /// overrides, and `StaffTextBase` channel and swing properties are not
    /// modeled and become preserved markup.
    ///
    /// `color`, `visible` and `offset` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads all three. A tag in
    /// this set is excluded from preserved markup, so it may only be listed
    /// once something actually reads it — otherwise it lands in neither the
    /// model nor the bag and is dropped. `offset` was deliberately held back
    /// until the parity doc's §7.2 work landed; that is this commit.
    private static let consumedChildren: Set = [
        "preset", "visibleStrings", "StringData", "text", "color", "offset", "placement",
        "visible",
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
