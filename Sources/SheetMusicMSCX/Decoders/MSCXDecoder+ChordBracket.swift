import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordBracket {
    /// Every direct `<ChordBracket>` child this decoder reads. The inherited
    /// `Arpeggio` properties and anything else become preserved markup.
    private static let consumedChildren: Set = [
        "bracketHookLen", "bracketHookPos", "bracketRightSide",
        "color", "visible",
    ]

    /// Decode the first direct `<ChordBracket>` child of a `<Chord>`.
    ///
    /// **Upstream does not enforce one bracket per chord.** `Chord::add` routes
    /// `CHORD_BRACKET` to the bare `addEl` push (`dom/chord.cpp:665`,
    /// `dom/chordrest.h:208`) — unlike `ARPEGGIO`, which overwrites a single
    /// slot — the writer emits every `el()` entry (`rw/write/twrite.cpp:1177`),
    /// and the reader adds each one (`rw/read460/tread.cpp:2518`). Only the
    /// palette drop handler dedups, and only for arpeggios
    /// (`dom/chord.cpp:1596`). So a file with two brackets on one chord is
    /// reachable, and `Chord.bracket` being a single optional cannot hold it.
    ///
    /// The first survives and the rest produce one diagnostic rather than
    /// failing the score, matching the parser policy for embellishments. They
    /// cannot be rescued into preserved markup: `appendPreservedMarkup` drops
    /// any entry whose name was already written, and the modeled bracket
    /// occupies that name. Modeling `[ChordBracket]` is the real fix if a
    /// corpus ever shows this shape occurring.
    ///
    /// The branch lives in `TRead::readProperties(Chord*, …)`
    /// (`rw/read460/tread.cpp:2518`), not in the `ChordRest` overload. Note
    /// that `read460` is the module for files declaring 4.60–4.99, not "the 4.6
    /// reader": this branch arrived in `v4.7.0`, and `v4.6.5` cannot parse
    /// `<ChordBracket>` at all. See `ChordBracket`'s own doc comment.
    static func decode(inChord node: XMLTreeNode) -> ChordBracket? {
        let bracketNodes = node.all("ChordBracket")
        if bracketNodes.count > 1 {
            mscxDecoderWarn(
                code: "mscx.chordBracket.duplicateDropped",
                message: "Only the first <ChordBracket> is kept — "
                    + "\(bracketNodes.count - 1) additional dropped",
                location: "Chord/ChordBracket",
            )
        }
        return bracketNodes.first.map(decode)
    }

    /// Decode one `<ChordBracket>` without throwing. Invalid typed values
    /// degrade to an absent property under the parser's embellishment policy.
    /// C++: `TRead::read(ChordBracket*, …)`
    /// (`rw/read460/tread.cpp:1894`).
    ///
    /// `<bracketRightSide>` uses this package's "anything but `0` is true"
    /// convention, the same one `ElementProperties` applies to `<visible>`.
    /// Upstream instead reads a BOOL as `bool(e.readInt())`
    /// (`rw/read460/tread.cpp:362`), so non-numeric text is false there and
    /// true here. Only hand-edited input can reach the difference — MuseScore
    /// writes `0` or `1` — but it is a real divergence, not a match.
    private static func decode(_ node: XMLTreeNode) -> ChordBracket {
        var bracket = ChordBracket(
            hookLength: node.first("bracketHookLen").flatMap { Double($0.text) },
            hookPosition: node.first("bracketHookPos")
                .flatMap { HookPosition(rawValue: $0.text) },
            isRightSide: node.first("bracketRightSide").map { $0.text != "0" },
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        bracket.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return bracket
    }
}
