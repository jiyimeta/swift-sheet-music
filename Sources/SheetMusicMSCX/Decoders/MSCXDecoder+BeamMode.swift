import SheetMusicCore
import SheetMusicXMLTools

extension BeamMode {
    /// The first format revision that names the secondary-beam breaks `begin16` / `begin32`. Older files — MuseScore
    /// 2.x through 4.0 — wrote the same two modes as `begin32` / `begin64` (`rw/read400/tread.cpp:2428-2437`,
    /// `rw/read206/read206.cpp:1715-1722`).
    static let currentTokenRevision = 410

    /// The `<BeamMode>` of a `<Chord>` or `<Rest>`, read as `TRead::readProperties(ChordRest*)` reads it
    /// (`rw/read460/tread.cpp:2584`): `TConv::fromXml(…, BeamMode::AUTO)`, so an absent or unknown token is `auto`.
    /// An unknown token is reported, as the decoder reports every other value it cannot place. A file older than
    /// `currentTokenRevision` has its secondary-beam tokens renamed first, as MuseScore's older readers rename them.
    static func decode(in node: XMLTreeNode) -> BeamMode {
        guard var text = node.first("BeamMode")?.text else { return .auto }
        if let revision = MSCXParserContext.formatRevision, revision < currentTokenRevision {
            switch text {
            case "begin64": text = BeamMode.begin32.rawValue
            case "begin32": text = BeamMode.begin16.rawValue
            default: break
            }
        }
        if let mode = BeamMode(rawValue: text) { return mode }
        mscxDecoderWarn(
            code: "mscx.beamMode.unknownToken",
            message: "<BeamMode>\(text)</BeamMode> is not a MuseScore beam mode; read as auto",
        )
        return .auto
    }

    /// The token a file of `targetVersion` names this mode by: the older one for the 2.x and 3.x outputs, whose
    /// readers know `begin32` / `begin64` for the two secondary-beam breaks.
    func token(for targetVersion: MSCXVersion) -> String {
        switch (targetVersion, self) {
        case (.v2, .begin16), (.v3, .begin16): "begin32"
        case (.v2, .begin32), (.v3, .begin32): "begin64"
        default: rawValue
        }
    }
}
