import Foundation
import SheetMusicCore

extension InstrumentChannel {
    static func decode(_ node: XMLNode) throws -> InstrumentChannel {
        var channel = InstrumentChannel()
        channel.name = node.attributes["name"]
        if let valueText = node.first("program")?.attributes["value"], let program = Int(valueText) {
            channel.program = program
        }
        if let text = node.first("midiChannel")?.text, let value = Int(text) {
            channel.midiChannel = value
        }
        if let text = node.first("midiPort")?.text, let value = Int(text) {
            channel.midiPort = value
        }
        return channel
    }
}
