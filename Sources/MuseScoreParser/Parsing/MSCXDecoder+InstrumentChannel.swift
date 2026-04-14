import Foundation

extension InstrumentChannel {
    static func decode(_ node: XMLNode) throws -> InstrumentChannel {
        var channel = InstrumentChannel()
        channel.name = node.attributes["name"]
        if let programNode = node.first("program"),
           let valueText = programNode.attributes["value"],
           let program = Int(valueText) {
            channel.program = program
        }
        return channel
    }
}
