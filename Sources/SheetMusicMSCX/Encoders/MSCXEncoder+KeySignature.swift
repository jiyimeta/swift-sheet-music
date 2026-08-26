import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension KeySignature {
    /// MuseScore 3 and earlier stored a single `<accidental>` holding the key as *written* on the
    /// staff — a transposing part's file therefore carries the transposed signature, and the
    /// concert key has to be recovered from the instrument. MuseScore 4 added `<concertKey>` and
    /// writes both, with `<accidental>` still the written one.
    ///
    /// So the value written to `<accidental>` is `concertKey` shifted by the part's
    /// `writtenFifthsOffset` and respelled back into the writable `[-7, +7]` range. For a
    /// non-transposing part the offset is 0 and the output is unchanged, including the absence of
    /// `<accidental>` under `.v4` — which keeps every existing fixture byte-stable.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        let writtenKey = Score.respelledKey(concertKey + options.writtenFifthsOffset)
        switch options.targetVersion {
        case .v2, .v3:
            children.append(XMLTreeNode(name: "accidental", text: String(writtenKey)))
        case .v4:
            children.append(XMLTreeNode(name: "concertKey", text: String(concertKey)))
            if options.writtenFifthsOffset != 0 {
                children.append(XMLTreeNode(name: "accidental", text: String(writtenKey)))
            }
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "KeySig", children: children)
    }
}
