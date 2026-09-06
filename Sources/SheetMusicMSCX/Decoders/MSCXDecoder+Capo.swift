import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Capo {
    /// Every direct `<Capo>` child this decoder reads. `<style>`,
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
        "active", "fretPosition", "generateText", "transposeMode", "string",
        "text", "color", "visible",
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
            text: node.first("text").map(StaffText.plainText(of:)) ?? "",
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        capo.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return capo
    }
}
