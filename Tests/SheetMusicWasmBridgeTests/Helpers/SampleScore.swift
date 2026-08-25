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

    /// A three-measure score whose middle measure repeats.
    ///
    /// Playback needs one: with no repeat plan the unrolled sequence and the
    /// notated timeline are the same clock, so every conversion the playback
    /// bridge performs is the identity and a broken one still passes.
    static func repeatingScore() -> Score {
        func quarters(_ pitches: [Int]) -> [VoiceElement] {
            pitches.map { pitch in
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
            }
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [
                        Staff(measures: [
                            Measure(voices: [Voice(elements: quarters([60, 62, 64, 65]))]),
                            Measure(
                                voices: [Voice(elements: quarters([67, 69, 71, 72]))],
                                startRepeat: true,
                                endRepeatCount: 2,
                            ),
                            Measure(voices: [Voice(elements: quarters([64, 62, 60, 60]))]),
                        ]),
                    ],
                ),
            ],
            metaTags: ["workTitle": "wasm repeat", "composer": "test"],
            titleFrame: ScoreFrame(
                heightSp: 10,
                texts: [FrameText(style: .title, text: "wasm repeat")],
            ),
        )
    }

    /// `repeatingScore()` as a `.mscz` container.
    static func repeatingMscz() throws -> [UInt8] {
        try [UInt8](MSCZWriter.write(score: repeatingScore()))
    }

    /// A score with enough systems for `.page` layout to paginate.
    static func longScore(measureCount: Int = 40) -> Score {
        let measures = (0 ..< measureCount).map { index in
            Measure(
                voices: [
                    Voice(elements: [
                        .chord(Chord(
                            duration: .whole,
                            notes: ChordNotes([Note(pitch: 60 + index % 8, tpc: 14)]),
                        )),
                    ]),
                ],
            )
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(measures: measures)],
                ),
            ],
            metaTags: ["workTitle": "wasm long", "composer": "test"],
        )
    }

    /// A score with an authored page break in the middle.
    static func pageBreakScore() -> Score {
        let measures = (0 ..< 3).map { index in
            Measure(
                voices: [
                    Voice(elements: [
                        .chord(Chord(
                            duration: .whole,
                            notes: ChordNotes([Note(pitch: 60 + index, tpc: 14)]),
                        )),
                    ]),
                ],
                pageBreak: index == 1,
            )
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(measures: measures)],
                ),
            ],
            metaTags: ["workTitle": "wasm page break", "composer": "test"],
        )
    }

    /// A two-staff score, used to prove hidden-staff options reach layout.
    static func twoStaffScore() -> Score {
        let upper = [
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))),
            ])]),
        ]
        let lower = [
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 48, tpc: 14)]))),
            ])]),
        ]
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(measures: upper), Staff(measures: lower)],
                ),
            ],
            metaTags: ["workTitle": "wasm hidden staves", "composer": "test"],
        )
    }

    /// A two-part score with per-staff clefs and one hidden part, for the
    /// flattened staff descriptor surface.
    static func staffDescriptorScore() -> Score {
        let measure = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        ])])
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "piano",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [
                        Staff(defaultClefType: "G", measures: [measure]),
                        Staff(defaultClefType: "F", measures: [measure]),
                    ],
                ),
                Part(
                    id: "drums",
                    instrument: Instrument(id: "drums", longName: "Drums"),
                    staves: [Staff(defaultClefType: "PERC", measures: [measure])],
                    isVisibleInScore: false,
                ),
            ],
            metaTags: ["workTitle": "wasm staves", "composer": "test"],
        )
    }

    /// A four-measure score with one rehearsal mark at measure 1's downbeat.
    static func rehearsalMarkScore() -> Score {
        let measure = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        ])])
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(measures: [measure, measure, measure, measure])],
                ),
            ],
            systemMeasures: [
                SystemMeasure(),
                SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start,
                        element: .rehearsalMark(RehearsalMark(text: "B")),
                    ),
                ]),
                SystemMeasure(),
                SystemMeasure(),
            ],
            metaTags: ["workTitle": "wasm marks", "composer": "test"],
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

    static func mscz(score: Score) throws -> [UInt8] {
        try [UInt8](MSCZWriter.write(score: score))
    }
}
