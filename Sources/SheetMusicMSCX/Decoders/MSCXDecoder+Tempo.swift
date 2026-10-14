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
        let bps = Double(node.first("tempo")?.text ?? "2") ?? 2.0
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
    /// here.
    private static func decodeText(_ textNode: XMLTreeNode?, into tempo: inout Tempo) {
        guard let textNode, !textNode.children.isEmpty || !textNode.text.isEmpty else {
            tempo.visible = false
            return
        }
        let markup = StaffText.preservedTextMarkup(of: textNode)
        if let markup, tempo.isSynthesizedMarking(markup) { return }
        tempo.text = StaffText.plainText(of: textNode)
        tempo.preservedTextMarkup = markup
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
        let fallback: (NoteDuration, Int) = (.quarter, 0)
        guard followsText(node) else { return fallback }
        guard let text = node.first("text").map(StaffText.plainText(of:)),
              let printed = printedTempoValue(in: text),
              printed > 0,
              beatsPerSecond > 0
        else { return fallback }
        let quartersPerBeat = beatsPerSecond * 60 / printed
        return matchBeat(quartersPerBeat: quartersPerBeat) ?? fallback
    }

    /// The metronome number printed in a tempo marking — the 80 in "♩. = 80". Reads the first number after the last
    /// `=` (so a leading "Allegro 1:" or the note glyph don't get picked up); if there's no `=`, the first number in
    /// the whole string.
    private static func printedTempoValue(in text: String) -> Double? {
        // `lastIndex(of:)` rather than `range(of:options: .backwards)`:
        // the latter is umbrella-only and this target builds for wasm.
        let scope: String = if let equals = text.lastIndex(of: "=") {
            String(text[text.index(after: equals)...])
        } else {
            text
        }
        var digits = ""
        for ch in scope {
            if ch.isNumber || (ch == "." && !digits.isEmpty) {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }

    /// Snap a beat length (in quarter notes) to the nearest standard note value carrying 0–2 augmentation dots.
    /// Returns nil when nothing lands within tolerance.
    private static func matchBeat(
        quartersPerBeat target: Double,
    ) -> (note: NoteDuration, dots: Int)? {
        let bases: [NoteDuration] = [.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond]
        var best: (note: NoteDuration, dots: Int, error: Double)?
        for base in bases {
            for dots in 0 ... 2 {
                let beat = base.dotted(dots).asFraction
                let lengthInQuarters = (Double(beat.numerator) / Double(beat.denominator)) / 0.25
                let error = abs(lengthInQuarters - target)
                guard error < 0.01 else { continue }
                if error < (best?.error ?? .greatestFiniteMagnitude) {
                    best = (base, dots, error)
                }
            }
        }
        return best.map { ($0.note, $0.dots) }
    }
}
