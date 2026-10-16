import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Tempo {
    /// Every child `decode` reads — its own tags, `TextProperties`' and `ElementProperties`' — so the preserved bag
    /// keeps exactly what nothing models (`<musicSymbolSize>`, `<style>`, `<align>`, …).
    static let consumedTempoChildren: Set = [
        "tempo", "followText", "type", "play", "text",
        "face", "size", "bold", "italic", "underline", "strike", "frameType", "framePadding",
        "visible", "color", "offset", "placement", "autoplace",
    ]

    /// `TRead::read(TempoText*)` (`rw/read460/tread.cpp:617-653`): the number, `<play>`, `<followText>`, `<type>`, the
    /// text properties, and the text — derived when it is exactly the marking `metronomeMarking` prints for the decoded
    /// beat and number, authored otherwise. A marking with no text MuseScore opens hidden.
    static func decode(_ node: XMLTreeNode) throws -> Tempo {
        // Clamped as `TempoText::setTempo` does on read (`dom/tempotext.cpp:324-330`): 0 or a negative would trap the
        // SMF conversion downstream.
        let bps = Tempo.clampedBeatsPerSecond(Double(node.first("tempo")?.text ?? "2") ?? 2.0)
        let beat = decodeBeatUnit(node, beatsPerSecond: bps)
        var tempo = Tempo(
            beatsPerSecond: bps,
            properties: TextProperties.decode(node),
            beatNote: beat.note,
            beatDots: beat.dots,
            followText: followsText(node),
            textType: node.first("type").flatMap { TempoTextType(rawValue: $0.text) } ?? .normal,
            playsBack: (node.first("play").flatMap { Int($0.text) } ?? 1) != 0,
            preservedMarkup: node.preservedMarkup(consuming: consumedTempoChildren),
        )
        tempo.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        decodeText(node.first("text"), into: &tempo)
        return tempo
    }

    /// `<followText>` as MuseScore reads it (`readInt`): any non-zero value. Absent means off — MuseScore's default for
    /// a read marking, unlike one built in code.
    static func followsText(_ node: XMLTreeNode) -> Bool {
        (node.first("followText").flatMap { Int($0.text) } ?? 0) != 0
    }

    /// An empty `<text>` is what MuseScore replaces with "♩ = N" and hides (`tread.cpp:648-651`); a text equal to the
    /// derived marking stays derived, so a marking saved by this library or MuseScore's palette edits like one made
    /// here. A text of only whitespace counts as empty: MuseScore parses with `parse_default`
    /// (`xmlstreamreader.cpp:109`), which omits `parse_ws_pcdata`, so pugixml creates no character node for it and
    /// `readXml()` returns "". The hidden marking's replacement text is left derived rather than spelled with
    /// MuseScore's integer `lrint`: it is never drawn, and a save writes the derived spelling for it either way.
    private static func decodeText(_ textNode: XMLTreeNode?, into tempo: inout Tempo) {
        guard let textNode, !textNode.children.isEmpty || !textNode.text.isEmpty else {
            tempo.visible = false
            return
        }
        tempo.adoptText(StaffText.preservedTextMarkup(of: textNode), plainText: StaffText.plainText(of: textNode))
    }

    /// Recover the metronome beat unit from the marking. MuseScore stores playback tempo as a quarter-normalized
    /// `<tempo>` (beats/sec) but draws the marking in whatever note the author chose. When `<followText>` is non-zero
    /// the drawn value equals `beatsPerSecond * 60 / (beatLength / quarter)`, so the beat length in quarters is
    /// `beatsPerSecond * 60 / printedValue`. We read the printed number out of `<text>` and snap that ratio to the
    /// nearest standard note (0–2 dots). Falls back to a plain quarter when the text has no number, `followText` is
    /// off, or the ratio matches nothing — the same assumption the engine makes for an unannotated tempo. This mirrors
    /// MuseScore's TempoText math rather than parsing the (version-dependent) note glyph from the text.
    static func decodeBeatUnit(
        _ node: XMLTreeNode, beatsPerSecond: Double,
    ) -> (note: NoteDuration, dots: Int) {
        guard followsText(node), let text = node.first("text").map(StaffText.plainText(of:)) else {
            return (.quarter, 0)
        }
        return Tempo.beatUnit(inPrintedText: text, beatsPerSecond: beatsPerSecond)
    }
}
