import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension InstrumentChange {
    /// Decode an `<InstrumentChange>` element.
    ///
    /// Element order as MuseScore writes it (`rw/write/twrite.cpp:2128`):
    /// nested `<Instrument>`, then `<init>` when true, then the
    /// `TextBase` properties (`<offset>`, `<text>`, `<color>`,
    /// `<visible>`, font overrides).
    ///
    /// Error policy (see CLAUDE.md's three-way MSCX decoder policy):
    /// a change with NO nested `<Instrument>` at all is an embellishment
    /// failure — the instrument is dropped, the text kept, and a
    /// `ScoreDiagnostic` emitted. Offsets / colour / fonts fall back
    /// silently. The nested `<Instrument>` itself is decoded through
    /// `Instrument.decode`, which is where a structural failure would
    /// surface; the `try` here is what propagates it. As of today
    /// neither `Instrument.decode` nor `InstrumentChannel.decode`
    /// throws — every field they read has a permissive fallback — so
    /// this path is a contract, not observed behavior.
    static func decode(_ node: XMLTreeNode) throws -> InstrumentChange {
        let instrument: Instrument?
        if let instrumentNode = node.first("Instrument") {
            instrument = try Instrument.decode(instrumentNode)
        } else {
            instrument = nil
            mscxDecoderWarn(
                code: "mscx.instrumentChange.missingInstrument",
                message: "<InstrumentChange> has no nested <Instrument>; "
                    + "keeping the instruction text, playback unaffected.",
                location: node.first("text").map(StaffText.plainText(of:)),
            )
        }
        let text = node.first("text").map(StaffText.plainText(of:)) ?? ""
        let color = node.first("color").flatMap(StaffText.decodeColor(_:))
        let offset = node.first("offset")
            .map(StaffText.decodeOffset(_:)) ?? (0, 0)
        let isInit = (node.first("init")?.text).map { $0 != "0" } ?? false
        var change = InstrumentChange(
            text: text,
            instrument: instrument,
            offsetX: offset.0,
            offsetY: offset.1,
            color: color,
            isUserInitialized: isInit,
            properties: TextProperties.decode(node),
        )
        change.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return change
    }
}
