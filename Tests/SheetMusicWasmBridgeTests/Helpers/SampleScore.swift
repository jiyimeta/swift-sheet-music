import SheetMusicCore
import SheetMusicMSCX

/// Every input this suite uses is built in memory. A wasm test host has no
/// preopened directory unless one is passed on the command line, so a fixture
/// file would make the suite depend on how it was launched — and
/// `Tests/SheetMusicTests/Resources` is off limits regardless, being GPL-3.0
/// copies of MuseScore's own fixtures that must stay confined to that target.
enum SampleScore {
    /// A score with one staff and four quarter notes.
    ///
    /// The notes are load-bearing, not decoration: a score with only a title
    /// frame lays out to zero systems, so `computeLayout` returns a page with no
    /// commands and `pageBreaks` has no boundaries to report. Anything asserting
    /// on drawn output needs a staff that actually gets engraved.
    static func score(
        title: String = "wasm bridge",
        composer: String = "test",
        pitches: [Int] = [60, 62, 64, 65],
    ) -> Score {
        let elements = pitches.map { pitch in
            VoiceElement.chord(
                Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])),
            )
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(measures: [Measure(voices: [Voice(elements: elements)])])],
                ),
            ],
            metaTags: ["workTitle": title, "composer": composer],
            titleFrame: ScoreFrame(
                heightSp: 10,
                texts: [FrameText(style: .title, text: title)],
            ),
        )
    }

    /// The same score as a `.mscz` container, which is what a browser host
    /// actually hands `loadScore`.
    static func mscz(
        title: String = "wasm bridge",
        composer: String = "test",
        pitches: [Int] = [60, 62, 64, 65],
    ) throws -> [UInt8] {
        try [UInt8](
            MSCZWriter.write(score: score(title: title, composer: composer, pitches: pitches)),
        )
    }
}
