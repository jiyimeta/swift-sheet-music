import Foundation

extension Measure {
    static func decode(_ node: XMLNode) throws -> Measure {
        let startRepeat = node.children.contains(where: { $0.name == "startRepeat" })
        let endRepeatCount: Int?
        if let text = node.first("endRepeat")?.text, let count = Int(text) {
            endRepeatCount = count
        } else {
            endRepeatCount = nil
        }

        let voiceNodes = node.all("voice")
        let voices: [Voice]
        if !voiceNodes.isEmpty {
            voices = try voiceNodes.map { try Voice.decode($0) }
        } else {
            // Older / simpler mscx form: musical elements are direct children of <Measure>
            // (no <voice> wrapper). Treat them as a single implicit voice.
            voices = [try Voice.decode(node)]
        }
        return Measure(voices: voices, startRepeat: startRepeat, endRepeatCount: endRepeatCount)
    }
}
