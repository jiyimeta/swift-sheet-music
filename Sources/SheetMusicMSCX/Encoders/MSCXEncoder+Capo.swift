import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Capo {
    /// Build the `<Capo>` element. Inverse of `MSCXDecoder+Capo`.
    ///
    /// Child order follows `TWrite::write(const Capo*, ...)`
    /// (`rw/write/twrite.cpp:1298`). The three MuseScore 4.6 scalar properties
    /// are written unconditionally: explicit defaults keep
    /// decode/encode/decode stable without duplicating `Capo::propertyDefault`
    /// logic here. MuseScore 4.7's `<transposeMode>` is emitted only when the
    /// model retained a tag. Ignored strings are sorted to mirror upstream's
    /// `std::set` write order.
    ///
    /// `<Capo>` is a MuseScore **4.1**-and-later element. `<transposeMode>` is
    /// newer still: v4.6.5's property table, reader, and writer lack it;
    /// `2ad8dd61a8` added it and v4.7.0 was its first release. It is therefore
    /// never synthesized into a file whose model did not carry the tag. A
    /// v3-target encode emits a capo MuseScore 3 drops, the same known
    /// limitation as `<Expression>` and `<MeasureRepeat>`; no v3
    /// down-conversion is attempted.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [
            XMLTreeNode(name: "active", text: isActive ? "1" : "0"),
            XMLTreeNode(name: "fretPosition", text: String(fretPosition)),
            XMLTreeNode(name: "generateText", text: generatesText ? "1" : "0"),
        ]
        if let transposeMode {
            children.append(XMLTreeNode(
                name: "transposeMode",
                text: String(transposeMode.mscxOrdinal),
            ))
        }
        for string in ignoredStrings.sorted() {
            children.append(XMLTreeNode(
                name: "string",
                attributes: ["no": String(string)],
                children: [XMLTreeNode(name: "apply", text: "0")],
            ))
        }
        children.append(XMLTreeNode(name: "text", text: text))
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Capo", children: children)
    }
}
