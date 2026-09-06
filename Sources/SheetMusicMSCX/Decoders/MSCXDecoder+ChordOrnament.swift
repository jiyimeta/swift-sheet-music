import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordOrnament {
    /// Every direct `<Ornament>` child this decoder reads. Everything else —
    /// the cue-note `<Chord>`, `<direction>`, and `<placement>` — becomes
    /// preserved markup. The base `<offset>` is owned by `ElementProperties`.
    ///
    /// `color` is consumed because `ElementProperties(decodingMSCXChildrenOf:)`
    /// reads it, following every other decoder in this package. The shared
    /// trailing writer emits it after preserved markup so a `<style>` cannot
    /// reset it on the next read.
    private static let consumedChildren: Set = [
        "Accidental", "intervalAbove", "intervalBelow", "ornamentShowAccidental",
        "ornamentShowCueNote", "ornamentStyle", "play", "startOnUpperNote",
        "subtype", "color", "offset", "visible",
    ]

    /// The `<Ornament>` children of a `<Chord>`, in document order.
    ///
    /// `XMLTreeNode.all` matches direct children only, so an `<Ornament>` nested
    /// inside this chord's own cue-note `<Chord>` is not picked up here.
    ///
    /// Rests are not covered. MuseScore reads `<Ornament>` in
    /// `TRead::readProperties(ChordRest*, …)`, so a rest can carry one, but this
    /// package's `Rest` models no articulation either — an ornament on a rest
    /// keeps round-tripping through that decoder's preserved markup, which is
    /// the same treatment `<Articulation>` gets there.
    static func decodeAll(inChord node: XMLTreeNode) -> [ChordOrnament] {
        node.all("Ornament").map(decode)
    }

    /// Decode one `<Ornament>`.
    ///
    /// Nothing here throws: the parser policy treats an ornament as an
    /// embellishment, so a malformed one degrades rather than failing the score.
    /// C++: `TRead::readProperties(Ornament*, …)`, `rw/read460/tread.cpp:1916`.
    static func decode(_ node: XMLTreeNode) -> ChordOrnament {
        let (above, below) = decodeAccidentals(node)
        var ornament = ChordOrnament(
            kind: decodeKind(node),
            intervalAbove: node.first("intervalAbove").map { Interval(mscxToken: $0.text) },
            intervalBelow: node.first("intervalBelow").map { Interval(mscxToken: $0.text) },
            showAccidental: decodeShowAccidental(node),
            showCueNote: node.first("ornamentShowCueNote")
                .flatMap { CueNoteVisibility(rawValue: $0.text) },
            startOnUpperNote: node.first("startOnUpperNote").map { $0.text != "0" },
            ornamentStyle: node.first("ornamentStyle").flatMap { Style(rawValue: $0.text) },
            plays: node.first("play").map { $0.text != "0" },
            accidentalAbove: above,
            accidentalBelow: below,
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        ornament.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return ornament
    }

    /// `<subtype>` is the SymId name. A subtype outside the modeled palette is
    /// kept verbatim as `.unknown`; an absent one is a shape MuseScore's writer
    /// never produces, so it is reported and kept as an empty `.unknown` rather
    /// than guessed at — inventing `ornamentTrill` there would write a symbol
    /// into the file that the author never placed.
    private static func decodeKind(_ node: XMLTreeNode) -> Kind {
        guard let subtype = node.first("subtype")?.text, !subtype.isEmpty else {
            mscxDecoderWarn(
                code: "mscx.ornament.missingSubtype",
                message: "<Ornament> without <subtype> — kept as an unnamed ornament",
                location: "Chord/Ornament",
            )
            return .unknown(subtype: "")
        }
        return Kind(mscxToken: subtype) ?? .unknown(subtype: subtype)
    }

    /// `<ornamentShowAccidental>` is persisted as the enum's ordinal, not a
    /// name — MuseScore reads it with `OrnamentShowAccidental(e.readInt())`
    /// (`rw/read460/tread.cpp:385`). An ordinal outside the enum degrades to
    /// `nil` (the tag's default) after a diagnostic.
    private static func decodeShowAccidental(_ node: XMLTreeNode) -> ShowAccidental? {
        guard let text = node.first("ornamentShowAccidental")?.text else { return nil }
        guard let ordinal = Int(text), let value = ShowAccidental(rawValue: ordinal) else {
            mscxDecoderWarn(
                code: "mscx.ornament.unsupportedShowAccidental",
                message: "Unknown <ornamentShowAccidental> '\(text)' — using the default",
                location: "Chord/Ornament",
            )
            return nil
        }
        return value
    }

    /// The accidentals drawn on the auxiliary notes.
    ///
    /// MuseScore files the child by its placement — `placement() ==
    /// PlacementV::ABOVE ? setAccidentalAbove : setAccidentalBelow`
    /// (`rw/read460/tread.cpp:1928`) — and `PlacementV` defaults to `BELOW`
    /// (`dom/engravingitem.cpp:1689`), so the above accidental is the one
    /// carrying an explicit `<placement>above</placement>` and the below one is
    /// written bare.
    private static func decodeAccidentals(
        _ node: XMLTreeNode,
    ) -> (above: Accidental?, below: Accidental?) {
        var above: Accidental?
        var below: Accidental?
        for accidentalNode in node.all("Accidental") {
            guard let subtype = accidentalNode.first("subtype")?.text else { continue }
            guard let accidental = Accidental(mscxSubtype: subtype) else {
                mscxDecoderWarn(
                    code: "mscx.ornament.unsupportedAccidental",
                    message: "Unknown <Accidental><subtype> '\(subtype)' — accidental dropped",
                    location: "Chord/Ornament/Accidental",
                )
                continue
            }
            if accidentalNode.first("placement")?.text == "above" {
                above = accidental
            } else {
                below = accidental
            }
        }
        return (above, below)
    }
}
