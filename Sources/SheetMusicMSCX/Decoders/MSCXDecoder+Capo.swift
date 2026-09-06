import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Capo {
    /// Every direct `<Capo>` child this decoder reads. `<style>`, font
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
        "active", "fretPosition", "generateText", "transposeMode", "string",
        "text", "color", "offset", "placement", "visible",
    ]

    /// Decode one `<Capo>`.
    ///
    /// Nothing throws: a capo is an embellishment under the parser policy, so
    /// malformed optional values fall back or are skipped rather than failing
    /// the score. C++: `TRead::read(Capo*, ...)`
    /// (`rw/read460/tread.cpp:2720`). That module spans MSCX 4.60–4.99 and
    /// therefore also contains properties introduced after MuseScore 4.6.
    static func decode(_ node: XMLTreeNode) -> Capo {
        let ignoredStrings = Set(node.all("string").compactMap { child -> Int? in
            guard let number = child.attributes["no"].flatMap(Int.init),
                  child.first("apply")?.text == "0"
            else { return nil }
            return number
        })
        let textNode = node.first("text")
        var capo = Capo(
            isActive: node.first("active").map { $0.text != "0" } ?? true,
            // Absence takes `Capo::propertyDefault` (1), while a present but
            // unreadable integer follows MuseScore's `readInt()` result (0).
            fretPosition: node.first("fretPosition").map { Int($0.text) ?? 0 } ?? 1,
            generatesText: node.first("generateText").map { $0.text != "0" } ?? true,
            transposeMode: node.first("transposeMode")
                .flatMap { Int($0.text) }
                .map(TransposeMode.init(mscxOrdinal:)),
            ignoredStrings: ignoredStrings,
            text: textNode.map(StaffText.plainText(of:)) ?? "",
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
            preservedTextMarkup: textNode.flatMap(StaffText.preservedTextMarkup(of:)),
        )
        capo.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return capo
    }
}
