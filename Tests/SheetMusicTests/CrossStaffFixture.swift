import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX

/// MSCX scores for the cross-staff (`<staffMove>`) tests: a two-staff piano — treble over bass — whose measures are
/// given as raw `<voice>` bodies, one string per measure and staff, optionally followed by more parts.
enum CrossStaffFixture {
    /// A `<Chord>` of `pitches` (MIDI pitch, tpc) with an optional `<staffMove>` and extra children.
    static func chord(
        _ pitches: [(Int, Int)], _ type: String = "quarter", move: Int? = nil, extra: String = "",
    ) -> String {
        let moveTag = move.map { "<staffMove>\($0)</staffMove>" } ?? ""
        let notes = pitches.map { "<Note><pitch>\($0.0)</pitch><tpc>\($0.1)</tpc></Note>" }.joined()
        return "<Chord>\(moveTag)<durationType>\(type)</durationType>\(extra)\(notes)</Chord>"
    }

    static func rest(_ type: String = "quarter", move: Int? = nil) -> String {
        let moveTag = move.map { "<staffMove>\($0)</staffMove>" } ?? ""
        if type == "measure" {
            return "<Rest>\(moveTag)<durationType>measure</durationType><duration>4/4</duration></Rest>"
        }
        return "<Rest>\(moveTag)<durationType>\(type)</durationType></Rest>"
    }

    static let fourFour = "<TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>"

    /// A piano score: `treble[i]` and `bass[i]` are measure `i`'s voice-0 bodies (the first measure's get a 4/4 time
    /// signature put in front). `bassStaffChildren` lands in the bass staff's `<Part><Staff>` (an `<isStaffVisible>`,
    /// say); `trailingParts` is appended after the piano part, with its own top-level staves in `trailingStaves`.
    static func piano(
        treble: [String], bass: [String],
        trebleVoice1: [String]? = nil,
        bassStaffChildren: String = "", bassGroup: String = "pitched",
        trailingParts: String = "", trailingStaves: String = "",
        style: String = "",
    ) -> Data {
        func staff(_ bodies: [String], voice1: [String]? = nil) -> String {
            bodies.enumerated().map { index, body in
                let voice0 = "<voice>\(index == 0 ? fourFour : "")\(body)</voice>"
                let second = voice1.map { "<voice>\($0[index])</voice>" } ?? ""
                return "<Measure>\(voice0)\(second)</Measure>"
            }.joined()
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division><Style>\(style)</Style>
        <Part id="1">
          <Staff><StaffType group="pitched"><name>stdNormal</name></StaffType>\
        <bracket type="1" span="2" col="0" visible="1"/></Staff>
          <Staff><StaffType group="\(bassGroup)"><name>stdNormal</name></StaffType>\
        <defaultClef>F</defaultClef>\(bassStaffChildren)</Staff>
          <trackName>Piano</trackName>
          <Instrument id="piano"><longName>Piano</longName></Instrument>
        </Part>
        \(trailingParts)
        <Staff id="1">\(staff(treble, voice1: trebleVoice1))</Staff>
        <Staff id="2">\(staff(bass))</Staff>
        \(trailingStaves)
        </Score></museScore>
        """
        return Data(xml.utf8)
    }

    static func parse(_ data: Data) throws -> Score {
        try MSCXParser.parse(data)
    }

    /// The chords and rests of voice `voice` of measure `measure` on staff `staff` of part 0.
    static func chords(_ score: Score, staff: Int, measure: Int = 0, voice: Int = 0) -> [Chord] {
        score.parts[0].staves[staff].measures[measure].voices[voice].elements.compactMap {
            if case let .chord(chord) = $0 { chord } else { nil }
        }
    }
}
