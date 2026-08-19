import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordLine {
    /// Decode a `<ChordLine>` element. C++: `TRead::read(ChordLine*, …)`
    /// in `engraving/rw/read460/tread.cpp`.
    ///
    /// `<subtype>` is the only load-bearing field. A missing or
    /// out-of-range value is `ChordLineType::NOTYPE`, which MuseScore
    /// lays out as an empty path — nothing is drawn. Per the decoder's
    /// embellishment policy that's a dropped element plus a
    /// `ScoreDiagnostic`, not a malformed score.
    ///
    /// `noteIndex` is supplied by the caller when the element was found
    /// under a `<Note>` rather than under `<Chord>`.
    static func decode(_ node: XMLTreeNode, noteIndex: Int? = nil) -> ChordLine? {
        let subtypeText = node.first("subtype")?.text ?? ""
        guard let rawSubtype = Int(subtypeText),
              let kind = ChordLine.Kind(rawValue: rawSubtype)
        else {
            mscxDecoderWarn(
                code: "mscx.chordLine.unknownSubtype",
                message: """
                <ChordLine> has unknown/missing <subtype> \
                "\(subtypeText)"; expected 1 (fall), 2 (doit), \
                3 (plop), or 4 (scoop). Dropping the element.
                """,
            )
            return nil
        }

        var line = ChordLine(
            kind: kind,
            isStraight: node.first("straight")?.text == "1",
            isWavy: node.first("wavy")?.text == "1",
            plays: (node.first("play")?.text ?? "1") != "0",
            lengthX: Double(node.first("lengthX")?.text ?? "") ?? 0,
            lengthY: Double(node.first("lengthY")?.text ?? "") ?? 0,
            path: decodePath(node.first("Path")),
            noteIndex: noteIndex,
        )
        line.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return line
    }

    /// Decode `<Path><Element type="N" x="…" y="…"/>…</Path>`.
    ///
    /// MuseScore scales the stored values by spatium on read; we keep
    /// them in spatium units so the encoder can write them back
    /// verbatim and layout can scale once, at the point of use.
    /// Elements with an unparsable `type` are skipped (permissive
    /// parser) — a partially-read path still beats discarding the
    /// user's edit wholesale.
    private static func decodePath(_ node: XMLTreeNode?) -> [PathElement] {
        guard let node else { return [] }
        return node.all("Element").compactMap { element in
            guard let rawKind = Int(element.attributes["type"] ?? ""),
                  let kind = PathElement.Kind(rawValue: rawKind)
            else { return nil }
            return PathElement(
                kind: kind,
                x: Double(element.attributes["x"] ?? "") ?? 0,
                y: Double(element.attributes["y"] ?? "") ?? 0,
            )
        }
    }

    /// Collect every `<ChordLine>` belonging to a `<Chord>` node: the
    /// chord-level children first, then the ones MuseScore nested
    /// inside each `<Note>` (which it does when the user attached the
    /// line to one specific note of the chord).
    ///
    /// C++: `TRead::readChord` handles the `<Chord>` form and
    /// `TRead::read(Note*, …)` the `<Note>` form; both end up in
    /// `Chord::add`.
    static func decodeAll(inChord node: XMLTreeNode) -> [ChordLine] {
        var result = node.all("ChordLine").compactMap { ChordLine.decode($0) }
        for (index, noteNode) in node.all("Note").enumerated() {
            result.append(contentsOf: noteNode.all("ChordLine").compactMap {
                ChordLine.decode($0, noteIndex: index)
            })
        }
        return result
    }
}
