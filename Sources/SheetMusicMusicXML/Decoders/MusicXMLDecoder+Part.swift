import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Part {
    /// Build a `Part` from the `<score-part>` entry in `<part-list>`. The
    /// actual `<part>` measures are walked separately by the Score decoder,
    /// which replaces the placeholder empty-measure staves with real content.
    /// `staffCount` must be ≥ 1 and controls how many `Staff`s are created
    /// (1 for a single-staff part, 2 for piano, etc.).
    /// Also returns the part's drum-mapping table (empty for non-percussion
    /// parts) so the note decoder can resolve `<unpitched>` notes to GM
    /// percussion pitches.
    static func decodeMusicXML(
        scorePart: XMLTreeNode,
        partId: String,
        staffCount: Int,
    ) throws -> (Part, MusicXMLDrumTable, [String: Instrument]) {
        let name = scorePart.first("part-name")?.text
        let abbrev = scorePart.first("part-abbreviation")?.text
        let drumTable = MusicXMLDrumTable.build(scorePart: scorePart)
        let (instrument, instrumentByID) = decodeInstrument(
            scorePart: scorePart, name: name, abbrev: abbrev,
            useDrumset: drumTable.isDrumset,
        )
        let count = max(1, staffCount)
        let staves = Array(
            repeating: Staff(
                staffType: "stdNormal", group: "pitched",
                defaultClefType: nil, measures: [],
            ),
            count: count,
        )
        let part = Part(
            id: partId,
            // MuseScore 5.x stores the track name on Instrument, not Part,
            // so leave Part.trackName nil for parity with `*_ref.mscx`.
            trackName: nil,
            instrument: instrument,
            staves: staves,
        )
        return (part, drumTable, instrumentByID)
    }

    /// MusicXML nests instrument metadata in `<score-instrument>` and
    /// `<midi-instrument>`. We surface names + track name; minPitch ranges and
    /// articulation playback data are MuseScore-template-only and are left
    /// defaulted. `ScoreSemanticComparison` normalizes both sides accordingly.
    /// `<score-instrument><instrument-name>` wins over `<part-name>` for
    /// `trackName` — MuseScore uses the more-specific instrument name.
    ///
    /// Also builds `byID`: every `<score-instrument>` in the `<score-part>`
    /// merged with its matching `<midi-instrument>` (joined by shared
    /// `id`), keyed by that same `id` — the string
    /// `<note><instrument id="…">` and MusicXML 4.0's
    /// `<sound><instrument-change id="…">` both reference.
    ///
    /// `primary` — the tick-0 / timeline-index-0 instrument — takes its
    /// CHANNELS from that same table, so one `<score-instrument>` is
    /// never decoded two different ways. It used to seed hard
    /// `InstrumentChannel()` defaults instead, which meant a non-piano
    /// part played GM program 0 until its first change, and a part that
    /// changed away and back produced two mixer strips for one
    /// instrument (the live dedup keys on exactly the fields the
    /// defaults were wrong about).
    ///
    /// `primary`'s IDENTITY — `id`, `longName`, `shortName`, `trackName`
    /// — is untouched: `ScoreSemanticComparison` and the MusicXML import
    /// tests pin those to the part-level values, not the table's.
    private static func decodeInstrument(
        scorePart: XMLTreeNode,
        name: String?,
        abbrev: String?,
        useDrumset: Bool,
    ) -> (primary: Instrument, byID: [String: Instrument]) {
        let scoreInstr = scorePart.first("score-instrument")
        let instrumentSound = scoreInstr?.first("instrument-sound")?.text
        let instrumentName = scoreInstr?.first("instrument-name")?.text
        let id = instrumentSound
            ?? scoreInstr?.attributes["id"]
            ?? scorePart.attributes["id"]
            ?? ""
        let trackName = instrumentName ?? name
        let byID = decodeInstrumentTable(
            scorePart: scorePart, partLongName: name, abbrev: abbrev, useDrumset: useDrumset,
        )
        // The first `<score-instrument>` is the one in force at tick 0.
        // Falls back to the defaults when the part declares none, or
        // declares one without an `id` attribute (which the table skips).
        let channels = scoreInstr?.attributes["id"]
            .flatMap { byID[$0]?.channels }
            ?? [InstrumentChannel()]
        let primary = Instrument(
            id: id,
            longName: name,
            shortName: abbrev,
            trackName: trackName,
            channels: channels,
            useDrumset: useDrumset,
        )
        return (primary, byID)
    }

    private static func decodeInstrumentTable(
        scorePart: XMLTreeNode,
        partLongName: String?,
        abbrev: String?,
        useDrumset: Bool,
    ) -> [String: Instrument] {
        let midiInstruments = scorePart.all("midi-instrument")
        var table: [String: Instrument] = [:]
        for scoreInstrNode in scorePart.all("score-instrument") {
            guard let scoreInstrID = scoreInstrNode.attributes["id"] else { continue }
            let instrumentSound = scoreInstrNode.first("instrument-sound")?.text
            let instrumentName = scoreInstrNode.first("instrument-name")?.text
            let midiNode = midiInstruments.first { $0.attributes["id"] == scoreInstrID }
            table[scoreInstrID] = Instrument(
                id: instrumentSound ?? scoreInstrID,
                longName: instrumentName ?? partLongName,
                shortName: abbrev,
                trackName: instrumentName ?? partLongName,
                channels: [decodeChannel(midiNode)],
                useDrumset: useDrumset,
            )
        }
        return table
    }

    /// `<midi-instrument>` unit conversions vs. `InstrumentChannel`:
    /// `<midi-program>` is 1-based MusicXML → 0-based `program`;
    /// `<midi-channel>` is 1-based → 0-based `midiChannel`; `<volume>` is a
    /// 0-100 percentage → MIDI CC 7's 0-127; `<pan>` is -90…90 degrees →
    /// 0-127 with 64 as center.
    private static func decodeChannel(_ midiInstrument: XMLTreeNode?) -> InstrumentChannel {
        var channel = InstrumentChannel()
        guard let node = midiInstrument else { return channel }
        if let text = node.first("midi-program")?.text, let program = Int(text) {
            channel.program = max(0, program - 1)
        }
        if let text = node.first("midi-channel")?.text, let midiChannel = Int(text) {
            channel.midiChannel = max(0, midiChannel - 1)
        }
        if let text = node.first("volume")?.text, let percent = Double(text) {
            channel.volume = min(127, max(0, Int((percent / 100.0 * 127.0).rounded())))
        }
        if let text = node.first("pan")?.text, let degrees = Double(text) {
            channel.pan = min(127, max(0, Int(((degrees + 90.0) / 180.0 * 127.0).rounded())))
        }
        return channel
    }
}
