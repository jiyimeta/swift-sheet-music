import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Part {
    /// Build a `Part` from the `<score-part>` entry in `<part-list>`. The
    /// actual `<part>` measures are walked separately by the Score decoder.
    /// `staffCount` must be ≥ 1 and controls how many `StaffDeclaration`s
    /// are emitted (1 for a single-staff part, 2 for piano, etc.).
    static func decodeMusicXML(
        scorePart: XMLTreeNode,
        partId: String,
        staffCount: Int
    ) throws -> Part {
        let name = scorePart.first("part-name")?.text
        let abbrev = scorePart.first("part-abbreviation")?.text
        let instrument = decodeInstrument(scorePart: scorePart, name: name, abbrev: abbrev)
        let count = max(1, staffCount)
        let declarations = Array(
            repeating: StaffDeclaration(staffType: "stdNormal", group: "pitched"),
            count: count
        )
        return Part(
            id: partId,
            // MuseScore 5.x stores the track name on Instrument, not Part,
            // so leave Part.trackName nil for parity with `*_ref.mscx`.
            trackName: nil,
            instrument: instrument,
            staffDeclarations: declarations
        )
    }

    /// MusicXML nests instrument metadata in `<score-instrument>` and
    /// `<midi-instrument>`. We surface names + track name; minPitch ranges and
    /// articulation playback data are MuseScore-template-only and are left
    /// defaulted. `ScoreSemanticComparison` normalises both sides accordingly.
    /// `<score-instrument><instrument-name>` wins over `<part-name>` for
    /// `trackName` — MuseScore uses the more-specific instrument name.
    private static func decodeInstrument(
        scorePart: XMLTreeNode,
        name: String?,
        abbrev: String?
    ) -> Instrument {
        let scoreInstr = scorePart.first("score-instrument")
        let instrumentSound = scoreInstr?.first("instrument-sound")?.text
        let instrumentName = scoreInstr?.first("instrument-name")?.text
        let id = instrumentSound
            ?? scoreInstr?.attributes["id"]
            ?? scorePart.attributes["id"]
            ?? ""
        let trackName = instrumentName ?? name
        return Instrument(
            id: id,
            longName: name,
            shortName: abbrev,
            trackName: trackName,
            channels: [InstrumentChannel()]
        )
    }
}
