import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension InstrumentChannel {
    /// Every `<Channel>` child this decoder reads. Anything else
    /// becomes preserved markup — see `PreservedXML`.
    private static let consumedChannelChildren: Set = [
        "controller", "midiChannel", "midiPort", "program",
    ]

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
        let automaticallyPreserved = node.preservedMarkup(consuming: consumedChannelChildren)
        channel.preservedMarkup = node.children.compactMap { child -> PreservedXML? in
            let preserved = PreservedXML(child)
            if child.name == "controller", shouldPreserveController(child) {
                return preserved
            }
            return automaticallyPreserved.contains(preserved) ? preserved : nil
        }
        return channel
    }

    /// A controller is preserved when this decoder cannot represent it,
    /// or when the encoder would elide its modeled default and thereby
    /// delete a source child. Non-default controllers represented by the
    /// channel model are emitted by the encoder and remain consumed.
    private static func shouldPreserveController(_ node: XMLTreeNode) -> Bool {
        guard let ctrlText = node.attributes["ctrl"],
              let ctrl = Int(ctrlText),
              let valueText = node.attributes["value"],
              let value = Int(valueText)
        else { return true }
        let defaults = InstrumentChannel()
        switch ctrl {
        case 0: return true
        case 7: return value == defaults.volume
        case 10: return value == defaults.pan
        case 32: return value == defaults.bank
        case 91: return value == defaults.reverb
        case 93: return value == defaults.chorus
        default: return true
        }
    }
}
