import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension KeySignature {
    /// MuseScore 3 and earlier stored a single `<accidental>` holding the key as *written* on the
    /// staff — a transposing part's file therefore carries the transposed signature, and the
    /// concert key has to be recovered from the instrument.
    ///
    /// MuseScore 4 writes the pair `<concertKey>` + `<actualKey>` instead
    /// (`TWrite::write(const KeySig*, …)`, `rw/write/twrite.cpp:2150-2160`) — `<accidental>` is not
    /// in the 4.6 reader's element table at all, so writing the written key under that name would
    /// have it silently discarded and a B♭ clarinet in concert C would open as C major rather than
    /// D. Hence the tag differs by generation while the value does not.
    ///
    /// That value is `concertKey` shifted by the part's `writtenFifthsOffset` and respelled back
    /// into the writable `[-7, +7]` range. For a non-transposing part the offset is 0, so v3 output
    /// is unchanged and v4 omits `<actualKey>` entirely — which keeps every existing fixture
    /// byte-stable.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        let writtenKey = Score.respelledKey(concertKey + options.writtenFifthsOffset)
        switch options.targetVersion {
        case .v2, .v3:
            children.append(XMLTreeNode(name: "accidental", text: String(writtenKey)))
        case .v4:
            children.append(XMLTreeNode(name: "concertKey", text: String(concertKey)))
            if options.writtenFifthsOffset != 0 {
                children.append(XMLTreeNode(name: "actualKey", text: String(writtenKey)))
            }
        }
        // MuseScore writes `<showCourtesySig>` after the key value and only when the courtesy is off
        // (`TWrite::write(const KeySig*, …)`), so the default omits the tag and existing fixtures stay
        // byte-stable.
        if !showCourtesy {
            children.append(XMLTreeNode(name: "showCourtesySig", text: "0"))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "KeySig", children: children)
    }
}
