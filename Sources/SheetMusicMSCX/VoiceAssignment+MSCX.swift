import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension VoiceAssignment {
    /// `<voiceAssignment>`, else an older file's `<dynType>`, else the whole instrument — as MuseScore 4 reads them
    /// (`rw/read460/tread.cpp:465-466`: an unknown value is the whole instrument).
    static func decode(_ node: XMLTreeNode) -> VoiceAssignment {
        if let text = node.first("voiceAssignment")?.text {
            return VoiceAssignment(rawValue: text.trimmingWhitespaceAndNewlines()) ?? .allInInstrument
        }
        if let text = node.first("dynType")?.text, let value = Int(text.trimmingWhitespaceAndNewlines()) {
            return VoiceAssignment(dynType: value)
        }
        return .allInInstrument
    }

    /// The child that saves it: none for the whole instrument; for MuseScore 4 `<voiceAssignment>`; for MuseScore 3
    /// `<dynType>0</dynType>` for the staff — MuseScore 3 has no voice-only reach, so `currentVoiceOnly` is not saved
    /// there.
    func mscxChild(options: MSCXEncoderOptions) -> XMLTreeNode? {
        switch (self, options.targetVersion) {
        case (.allInInstrument, _), (.currentVoiceOnly, .v2), (.currentVoiceOnly, .v3):
            nil
        case (.allInStaff, .v2), (.allInStaff, .v3):
            XMLTreeNode(name: "dynType", text: "0")
        case (_, .v4):
            XMLTreeNode(name: "voiceAssignment", text: rawValue)
        }
    }
}
