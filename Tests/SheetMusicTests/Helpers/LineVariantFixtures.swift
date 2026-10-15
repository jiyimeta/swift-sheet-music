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
