import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Instrument {
    static func decode(_ node: XMLTreeNode) throws -> Instrument {
        // Both `<Instrument id="...">` and `<Instrument><instrumentId>...` forms exist;
        // some scores omit both — fall back to "" rather than failing.
        let id = node.attributes["id"] ?? node.first("instrumentId")?.text ?? ""
        let articulations = try node.all("Articulation").map { try InstrumentArticulation.decode($0) }
        let channelNodes = node.all("Channel")
        let channels: [InstrumentChannel]
        if channelNodes.isEmpty {
            channels = [InstrumentChannel()]
        } else {
            channels = try channelNodes.map { try InstrumentChannel.decode($0) }
        }
        // MuseScore 5.x wraps longName/shortName inside <InstrumentLabel>;
        // MuseScore 4.x has them as direct children. Accept either.
        let label = node.first("InstrumentLabel")
        let longName = label?.first("longName")?.text ?? node.first("longName")?.text
        let shortName = label?.first("shortName")?.text ?? node.first("shortName")?.text
        // <useDrumset>1</useDrumset> marks the instrument as a percussion kit.
        // The renderer routes drumset parts to GM channel 10 (0-indexed: 9).
        let useDrumset = (node.first("useDrumset")?.text).flatMap { Int($0) } == 1
        // <Drum pitch="42"><head>cross</head><line>-1</line><voice>0</voice><name>…</name><stem>1</stem></Drum>
        // — the whole per-pitch engraving entry. `<line>` is the one child that is load-bearing enough to skip
        // the entry over: without it there is nothing to place the notehead by. The others fall back to the GM
        // conventions rather than dropping the drum, because a `<Drum>` that reaches MuseScore without them is
        // ignored outright.
        var drumset: [Int: DrumsetEntry] = [:]
        for drum in node.all("Drum") {
            guard let pitchStr = drum.attributes["pitch"],
                  let pitch = Int(pitchStr),
                  let lineStr = drum.first("line")?.text,
                  let line = Int(lineStr) else { continue }
            let fallback = GMDrumset.entry(forPitch: pitch, line: line)
            drumset[pitch] = DrumsetEntry(
                name: drum.first("name")?.text ?? fallback.name,
                head: drum.first("head")?.text ?? fallback.head,
                line: line,
                voiceIndex: (drum.first("voice")?.text).flatMap { Int($0) } ?? fallback.voiceIndex,
                stem: (drum.first("stem")?.text).flatMap { Int($0) } ?? fallback.stem,
                shortcut: drum.first("shortcut")?.text,
            )
        }
        return Instrument(
            id: id,
            longName: longName,
            shortName: shortName,
            trackName: node.first("trackName")?.text,
            minPitchPlayable: node.first("minPitchP").flatMap { Int($0.text) },
            maxPitchPlayable: node.first("maxPitchP").flatMap { Int($0.text) },
            minPitchAmateur: node.first("minPitchA").flatMap { Int($0.text) },
            maxPitchAmateur: node.first("maxPitchA").flatMap { Int($0.text) },
            articulations: articulations,
            channels: channels,
            useDrumset: useDrumset,
            drumset: drumset,
            // `<transposeDiatonic>` / `<transposeChromatic>` are omitted for a concert-pitch
            // instrument; both default to 0, which `Instrument` reads as non-transposing.
            transposeDiatonic: node.first("transposeDiatonic").flatMap { Int($0.text) } ?? 0,
            transposeChromatic: node.first("transposeChromatic").flatMap { Int($0.text) } ?? 0,
        )
    }
}
