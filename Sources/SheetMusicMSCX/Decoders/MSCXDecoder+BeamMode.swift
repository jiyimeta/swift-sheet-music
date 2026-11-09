import SheetMusicCore
import SheetMusicXMLTools

extension BeamMode {
    /// The `<BeamMode>` of a `<Chord>` or `<Rest>`, read as `TRead::readProperties(ChordRest*)` reads it
    /// (`rw/read460/tread.cpp:2584`): `TConv::fromXml(…, BeamMode::AUTO)`, so an absent or unknown token is `auto`.
    /// An unknown token is reported, as the decoder reports every other value it cannot place.
    static func decode(in node: XMLTreeNode) -> BeamMode {
        guard let text = node.first("BeamMode")?.text else { return .auto }
        if let mode = BeamMode(rawValue: text) { return mode }
        mscxDecoderWarn(
            code: "mscx.beamMode.unknownToken",
            message: "<BeamMode>\(text)</BeamMode> is not a MuseScore beam mode; read as auto",
        )
        return .auto
    }
}
