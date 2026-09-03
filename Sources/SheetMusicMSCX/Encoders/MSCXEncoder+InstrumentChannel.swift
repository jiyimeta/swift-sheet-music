import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension InstrumentChannel {
    /// Build the `<Channel>` element.
    ///
    /// MuseScore's parser fills missing CC values from the
    /// `InstrumentChannel()` defaults (volume=100, pan=64, reverb=0,
    /// chorus=0, bank=0). To stay faithful to the parsed-then-encoded
    /// round-trip, we emit `<controller>` entries only when the
    /// current value differs from those defaults, so a value parsed
    /// from a fixture without explicit controllers re-encodes to the
    /// same shape.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = switch options.targetVersion {
        case .v2, .v3: v3Children()
        case .v4: v4Children()
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        var attrs: [String: String] = [:]
        if let name { attrs["name"] = name }
        return XMLTreeNode(name: "Channel", attributes: attrs, children: children)
    }

    private func v3Children() -> [XMLTreeNode] {
        let defaults = InstrumentChannel()
        var children: [XMLTreeNode] = []
        // Canonical MS3 form: Bank MSB+LSB pair always emitted, before <program>.
        children.append(controllerNode(ctrl: 0, value: bank))
        children.append(controllerNode(ctrl: 32, value: 0))
        children.append(XMLTreeNode(
            name: "program",
            attributes: ["value": String(program)],
        ))
        if let midiChannel, midiChannel != 0 {
            children.append(XMLTreeNode(
                name: "midiChannel", text: String(midiChannel),
            ))
        }
        if let midiPort, midiPort != 0 {
            children.append(XMLTreeNode(
                name: "midiPort", text: String(midiPort),
            ))
        }
        if volume != defaults.volume {
            children.append(controllerNode(ctrl: 7, value: volume))
        }
        if pan != defaults.pan {
            children.append(controllerNode(ctrl: 10, value: pan))
        }
        if reverb != defaults.reverb {
            children.append(controllerNode(ctrl: 91, value: reverb))
        }
        if chorus != defaults.chorus {
            children.append(controllerNode(ctrl: 93, value: chorus))
        }
        return children
    }

    private func v4Children() -> [XMLTreeNode] {
        let defaults = InstrumentChannel()
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(
            name: "program",
            attributes: ["value": String(program)],
        ))
        if let midiChannel {
            children.append(XMLTreeNode(
                name: "midiChannel", text: String(midiChannel),
            ))
        }
        if let midiPort {
            children.append(XMLTreeNode(
                name: "midiPort", text: String(midiPort),
            ))
        }
        if volume != defaults.volume {
            children.append(controllerNode(ctrl: 7, value: volume))
        }
        if pan != defaults.pan {
            children.append(controllerNode(ctrl: 10, value: pan))
        }
        if bank != defaults.bank {
            children.append(controllerNode(ctrl: 32, value: bank))
        }
        if reverb != defaults.reverb {
            children.append(controllerNode(ctrl: 91, value: reverb))
        }
        if chorus != defaults.chorus {
            children.append(controllerNode(ctrl: 93, value: chorus))
        }
        return children
    }

    private func controllerNode(ctrl: Int, value: Int) -> XMLTreeNode {
        XMLTreeNode(
            name: "controller",
            attributes: ["ctrl": String(ctrl), "value": String(value)],
        )
    }
}
