import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX

/// Builders for the line-variant tests: a hand-written MSCX measure body parsed into a `Score`, the spanners of a
/// score flattened, and a one-measure score around a single spanner.
enum LineVariantFixtures {
    /// A score of one measure whose voice holds `measureBody` (MSCX voice children), wrapped in the minimal
    /// Score / Part / Staff envelope the other round-trip tests use.
    static func score(_ measureBody: String) throws -> Score {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  \(measureBody)
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        return try MSCXParser.parse(Data(xml.utf8))
    }

    /// Every `.spanner` voice element of `score`, in score order (staff, measure, voice, element).
    static func spanners(in score: Score) -> [Spanner] {
        score.parts.flatMap(\.staves).flatMap(\.measures).flatMap(\.voices).flatMap { voice in
            voice.elements.values.compactMap { element -> Spanner? in
                guard case let .spanner(spanner) = element else { return nil }
                return spanner
            }
        }
    }

    /// A one-measure score holding `spanner` followed by one whole-note chord.
    static func score(spanner: Spanner) -> Score {
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        let voice = Voice(elements: [.spanner(spanner), .chord(chord)])
        let staff = Staff(measures: [Measure(voices: [voice])])
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
    }
}

extension LineVariantFixtures {
    /// A score of `bars` 4/4 measures of four quarter chords with one pedal: `payload` (the begin side's `<Pedal…>`
    /// element) at the start of bar `from`, ending at the end of bar `from + over - 1`, with the matching payload-less
    /// end side (`<prev>`) placed there.
    static func score(pedal payload: String, bars: Int, from: Int, over: Int) throws -> Score {
        try score(pedals: [(payload, from, over)], bars: bars)
    }

    /// Like `score(pedal:bars:from:over:)` for several pedals, each `(payload, from, over)`.
    static func score(pedals: [(payload: String, from: Int, over: Int)], bars: Int) throws -> Score {
        let measures = (0 ..< bars).map { bar -> String in
            var body = ""
            if bar == 0 {
                body += "<TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>\n"
            }
            for pedal in pedals where pedal.from == bar {
                body += pedalBegin(payload: pedal.payload, over: pedal.over)
            }
            for step in 0 ..< 4 {
                body += """
                <Chord><durationType>quarter</durationType><Note><pitch>\(60 + step)</pitch><tpc>14</tpc></Note></Chord>

                """
            }
            for pedal in pedals where pedal.from + pedal.over - 1 == bar {
                body += pedalEnd(over: pedal.over)
            }
            return "<Measure><voice>\n\(body)</voice></Measure>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              \(measures.joined(separator: "\n"))
            </Staff>
          </Score>
        </museScore>
        """
        return try MSCXParser.parse(Data(xml.utf8))
    }

    /// The begin side: the payload, then `<next>` — `over - 1` whole measures (omitted for 0) plus one whole note of
    /// fractions, which lands on the end of the last covered bar (the shape `own/pedal-lines.mscx` carries).
    private static func pedalBegin(payload: String, over: Int) -> String {
        let measures = over > 1 ? "<measures>\(over - 1)</measures>" : ""
        return """
        <Spanner type="Pedal">\(payload)<next><location>\(measures)<fractions>1/1</fractions></location></next>\
        </Spanner>

        """
    }

    private static func pedalEnd(over: Int) -> String {
        let measures = over > 1 ? "<measures>\(1 - over)</measures>" : ""
        return """
        <Spanner type="Pedal"><prev><location>\(measures)<fractions>-1/1</fractions></location></prev></Spanner>

        """
    }
}
