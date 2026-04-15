import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    static func decode(_ node: XMLTreeNode) throws -> Voice {
        var elements: [VoiceElement] = []
        elements.reserveCapacity(node.children.count)
        for child in node.children {
            switch child.name {
            case "Chord":
                elements.append(.chord(try Chord.decode(child)))
            case "Rest":
                elements.append(.rest(try Rest.decode(child)))
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
            case "MeasureRepeat":
                elements.append(.measureRepeat(try MeasureRepeat.decode(child)))
            case "Fermata":
                let subtype = child.first("subtype")?.text ?? ""
                elements.append(.fermata(Fermata(subtype: subtype)))
            default:
                // Unknown elements are silently ignored. Decoder is permissive on purpose
                // — once we see what features individual MIDI tests actually need, they
                // can be promoted to first-class VoiceElement cases.
                continue
            }
        }
        return Voice(elements: elements)
    }
}
