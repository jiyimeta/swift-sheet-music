import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension InstrumentChannel {
    static func decode(_ node: XMLTreeNode) throws -> InstrumentChannel {
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
        // <controller ctrl="N" value="V"/> entries on a Channel.
        // MuseScore writes initial CC values here — at minimum CC7
        // (Channel Volume) and bank-select (CC0 / CC32) are present
        // in every saved score; CC10 / CC91 / CC93 (pan, reverb,
        // chorus) appear when the user has touched those knobs.
        for controllerNode in node.all("controller") {
            guard
                let ctrlText = controllerNode.attributes["ctrl"],
                let ctrl = Int(ctrlText),
                let valueText = controllerNode.attributes["value"],
                let value = Int(valueText)
            else { continue }
            switch ctrl {
            case 0: // Bank Select MSB — currently unused (MuseScore
                // stores SF2 bank in the LSB; the MSB is the
                // melodic/percussion split which we infer from
                // `useDrumset`).
                break
            case 7: channel.volume = value
            case 10: channel.pan = value
            case 32: channel.bank = value // Bank Select LSB
            case 91: channel.reverb = value
            case 93: channel.chorus = value
            default: break
            }
        }
        return channel
    }
}
