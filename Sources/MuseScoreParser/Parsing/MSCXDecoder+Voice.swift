import Foundation

extension Voice {
    static func decode(_ node: XMLNode) throws -> Voice {
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
            default:
                throw MuseScoreParserError.unsupportedFeature(name: child.name, location: "Voice")
            }
        }
        return Voice(elements: elements)
    }
}
