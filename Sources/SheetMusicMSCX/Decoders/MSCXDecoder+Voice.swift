import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    private struct OpenTuplet {
        let ratio: Fraction
        let firstElementIndex: Int
    }

    static func decode(_ node: XMLTreeNode) throws -> Voice {
        var elements: [VoiceElement] = []
        elements.reserveCapacity(node.children.count)
        var tuplets: [Tuplet] = []
        // Stack of open tuplet ratios (normal/actual). Each <Tuplet>
        // pushes, each <endTuplet/> pops. Chord/Rest durations are
        // scaled by the product of every ratio on the stack — mirrors
        // MuseScore's positional state machine in
        // MeasureRead::readVoice. `firstElementIndex` records where
        // the tuplet's first member landed so we can finalise a
        // `Tuplet` range at `<endTuplet>`.
        var tupletStack: [OpenTuplet] = []
        func tupletFractions() -> [Fraction] {
            tupletStack.map(\.ratio)
        }
        for child in node.children {
            switch child.name {
            case "Chord":
                var chord = try Chord.decode(child)
                chord.duration = scaled(
                    chord.duration, by: tupletFractions())
                elements.append(.chord(chord))
            case "Rest":
                var rest = try MSCXRestDecoder.decode(child)
                rest.duration = scaled(
                    rest.duration, by: tupletFractions())
                elements.append(.chord(rest))
            case "Tuplet":
                if let ratio = tupletRatio(from: child) {
                    tupletStack.append(OpenTuplet(
                        ratio: ratio,
                        firstElementIndex: elements.count))
                }
            case "endTuplet":
                if let top = tupletStack.popLast() {
                    let endIndex = elements.count - 1
                    if endIndex >= top.firstElementIndex {
                        tuplets.append(Tuplet(
                            normalNotes: top.ratio.numerator,
                            actualNotes: top.ratio.denominator,
                            startIndex: top.firstElementIndex,
                            endIndex: endIndex))
                    }
                }
            case "KeySig":
                elements.append(.keySignature(try KeySignature.decode(child)))
            case "TimeSig":
                elements.append(.timeSignature(try TimeSignature.decode(child)))
            case "Clef":
                elements.append(.clef(try Clef.decode(child)))
            case "BarLine":
                elements.append(.barLine(try BarLine.decode(child)))
            case "Tempo":
                elements.append(.tempo(try Tempo.decode(child)))
            case "Dynamic":
                elements.append(.dynamic(try Dynamic.decode(child)))
            case "Spanner":
                elements.append(.spanner(try Spanner.decode(child)))
            case "MeasureRepeat", "RepeatMeasure":
                // <RepeatMeasure> is the MuseScore 3.x spelling of the same
                // element (see MeasureRead::readVoice in measureread.cpp:336).
                elements.append(.measureRepeat(try MeasureRepeat.decode(child)))
            case "Fermata":
                let subtype = child.first("subtype")?.text ?? ""
                elements.append(.fermata(Fermata(subtype: subtype)))
            case "StaffText":
                elements.append(.staffText(
                    try StaffText.decode(child, isSystemText: false)))
            case "SystemText":
                elements.append(.staffText(
                    try StaffText.decode(child, isSystemText: true)))
            case "RehearsalMark":
                elements.append(.rehearsalMark(
                    try RehearsalMark.decode(child)))
            default:
                // Unknown elements are silently ignored. Decoder is permissive on purpose
                // — once we see what features individual MIDI tests actually need, they
                // can be promoted to first-class VoiceElement cases.
                continue
            }
        }
        return Voice(elements: elements, tuplets: tuplets)
    }

    /// Parse a `<Tuplet>` element's ratio (normalNotes/actualNotes). A triplet's
    /// 3 notes occupy the time of 2 normal notes, so the scale is 2/3.
    private static func tupletRatio(from node: XMLTreeNode) -> Fraction? {
        guard let normalText = node.first("normalNotes")?.text,
              let actualText = node.first("actualNotes")?.text,
              let normal = Int(normalText),
              let actual = Int(actualText),
              normal > 0, actual > 0 else {
            return nil
        }
        return Fraction(numerator: normal, denominator: actual)
    }

    private static func scaled(_ duration: NoteDuration, by tupletStack: [Fraction]) -> NoteDuration {
        guard !tupletStack.isEmpty else { return duration }
        var frac = duration.asFraction
        for ratio in tupletStack {
            frac = Fraction(
                numerator: frac.numerator * ratio.numerator,
                denominator: frac.denominator * ratio.denominator
            )
        }
        return .fraction(frac)
    }
}
