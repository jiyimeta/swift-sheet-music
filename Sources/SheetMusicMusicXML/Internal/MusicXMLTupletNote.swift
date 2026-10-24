import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// What one chord or rest says about the tuplet it may belong to: its `<time-modification>`, its written value and the
/// `<tuplet>` marks in its `<notations>`. MuseScore reads the same facts in `MusicXmlNoteDuration::timeModification`
/// and `MusicXmlParserNotations::tuplet` (`importmusicxmlpass2.cpp`).
struct MusicXMLTupletNote {
    enum Mark {
        case start
        case stop
    }

    /// `<normal-notes>` and `<actual-notes>`; 1 and 1 when the note has no usable `<time-modification>`.
    let normalNotes: Int
    let actualNotes: Int
    /// `<normal-type>` without its dots — MuseScore's `isTupletFilled` compares the type alone.
    let normalType: Fraction?
    /// The note's written value, before the time modification scales it.
    let written: Fraction
    /// The smallest value the written one counts in: its type, halved once per dot (`smallestTypeAndCount`).
    let unit: Fraction
    let mark: Mark?
    /// The marking's look as the note's `<tuplet>` gives it, which a tuplet takes from the note that starts it.
    let appearance: TupletAppearance

    /// Nil for a note with neither a `<type>` nor a positive `<duration>`, which takes no time.
    init?(node: XMLTreeNode, divisions: DivisionsContext) {
        let modification = node.first("time-modification")
        let actual = modification?.first("actual-notes").flatMap { Int($0.text) } ?? 0
        let normal = modification?.first("normal-notes").flatMap { Int($0.text) } ?? 0
        if MusicXMLDuration.isUnmarkedTripletRest(note: node, divisions: divisions) {
            (actualNotes, normalNotes) = (3, 2)
        } else {
            (actualNotes, normalNotes) = actual > 0 && normal > 0 ? (actual, normal) : (1, 1)
        }
        normalType = modification?.first("normal-type")
            .flatMap { NoteDuration(mscxName: $0.text)?.asFraction }
        guard let value = Self.writtenValue(
            node, divisions: divisions, normalNotes: normalNotes, actualNotes: actualNotes,
        ) else { return nil }
        written = value.written
        unit = value.unit
        (mark, appearance) = Self.marks(node)
    }

    /// The 2:1 a two-note tremolo writes, which MuseScore keeps out of tuplets.
    var isTremolo: Bool {
        actualNotes == 2 * normalNotes
    }

    /// The time is modified, and not by a tremolo.
    var isTupletMember: Bool {
        normalNotes != actualNotes && !isTremolo
    }

    private static func writtenValue(
        _ node: XMLTreeNode, divisions: DivisionsContext, normalNotes: Int, actualNotes: Int,
    ) -> (written: Fraction, unit: Fraction)? {
        let dots = node.all("dot").count
        if let base = node.first("type").flatMap({ NoteDuration(mscxName: $0.text) }) {
            let unit = scaled(base.asFraction, by: 1, over: 1 << dots)
            return (base.dotted(dots).asFraction, unit)
        }
        guard let ticks = node.first("duration").flatMap({ Int($0.text) }), ticks > 0, divisions.perQuarter > 0
        else { return nil }
        let written = scaled(divisions.fractionOfWhole(ticks), by: actualNotes, over: normalNotes)
        guard let spelled = NoteDuration.fraction(written).baseAndDots() else {
            return (written, Fraction(numerator: 1, denominator: written.denominator))
        }
        return (written, scaled(spelled.base.asFraction, by: 1, over: 1 << spelled.dots))
    }

    /// The last `<tuplet>` type wins, as each one MuseScore parses overwrites the note's; `bracket` and `placement`
    /// keep the last one given, and `show-number` the last one's, which reads unset as the bare number.
    private static func marks(_ node: XMLTreeNode) -> (Mark?, TupletAppearance) {
        var mark: Mark?
        var appearance = TupletAppearance()
        for tuplet in node.all("notations").flatMap({ $0.all("tuplet") }) {
            switch tuplet.attributes["type"] {
            case "start": mark = .start
            case "stop": mark = .stop
            default: break
            }
            switch tuplet.attributes["bracket"] {
            case "yes": appearance.bracketType = .bracket
            case "no": appearance.bracketType = .noBracket
            default: break
            }
            switch tuplet.attributes["show-number"] {
            case "both": appearance.numberType = .ratio
            case "none": appearance.numberType = .noText
            default: appearance.numberType = nil
            }
            switch tuplet.attributes["placement"] {
            case "above": appearance.direction = .up
            case "below": appearance.direction = .down
            default: break
            }
        }
        return (mark, appearance)
    }
}

extension MusicXMLTupletNote {
    /// `value × numerator / denominator` — `Fraction` has no multiplication of its own.
    static func scaled(_ value: Fraction, by numerator: Int, over denominator: Int) -> Fraction {
        Fraction(numerator: value.numerator * numerator, denominator: value.denominator * denominator)
    }
}
