@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("Score.blank")
struct BlankScoreTests {
    private func pianoTemplate(measures: Int = 4) -> BlankScoreTemplate {
        BlankScoreTemplate(
            title: "My Piece", composer: "Me",
            parts: [.init(
                instrumentID: "piano", longName: "Piano",
                staves: [.init(clefType: "G"), .init(clefType: "F")],
            )],
            concertKey: 2, timeNumerator: 3, timeDenominator: 4,
            tempoBPM: 90, measureCount: measures,
        )
    }

    @Test("shape: parts, staves, parallel systemMeasures, signatures on every staff")
    func shape() {
        let score = Score.blank(pianoTemplate())
        #expect(score.division == 480)
        #expect(score.parts.count == 1)
        #expect(score.parts[0].id == "1")
        #expect(score.parts[0].staves.count == 2)
        #expect(score.systemMeasures.count == 4)
        for staff in score.parts[0].staves {
            #expect(staff.measures.count == 4)
            let first = staff.measures[0].voices[0].elements
            #expect(first[0] == .keySignature(KeySignature(concertKey: 2)))
            #expect(first[1] == .timeSignature(TimeSignature(numerator: 3, denominator: 4)))
            #expect(first[2].isMeasureRest)
            for measure in staff.measures.dropFirst() {
                #expect(measure.voices[0].elements == [.rest(duration: .measure)])
            }
        }
        #expect(score.parts[0].staves[0].defaultClefType == "G")
        #expect(score.parts[0].staves[1].defaultClefType == "F")
    }

    @Test("tempo lands on systemMeasures[0], grand staff gets a brace")
    func tempoAndBrace() {
        let score = Score.blank(pianoTemplate())
        let tempoElements = score.systemMeasures[0].elements
        #expect(tempoElements.count == 1)
        guard case let .tempo(tempo) = tempoElements[0].element else {
            Issue.record("expected a tempo"); return
        }
        #expect(abs(tempo.beatsPerSecond - 90.0 / 60.0) < 0.0001)
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
        #expect(score.parts[0].staves[1].brackets.isEmpty)
    }

    @Test("metadata: metaTags and title frame")
    func metadata() {
        let score = Score.blank(pianoTemplate())
        #expect(score.metaTags["workTitle"] == "My Piece")
        #expect(score.metaTags["composer"] == "Me")
        let texts = score.titleFrame?.texts ?? []
        #expect(texts.contains(FrameText(style: .title, text: "My Piece")))
        #expect(texts.contains(FrameText(style: .composer, text: "Me")))
    }

    @Test("single-staff template omits brace, nil composer omits composer text")
    func singleStaff() {
        var template = pianoTemplate()
        template.parts[0].staves = [.init(clefType: "G")]
        template.composer = nil
        let score = Score.blank(template)
        #expect(score.parts[0].staves[0].brackets.isEmpty)
        #expect(score.metaTags["composer"] == nil)
        #expect(!(score.titleFrame?.texts ?? []).contains { $0.style == .composer })
    }

    @Test("round-trips through the mscx encoder semantically")
    func roundTrip() throws {
        let score = Score.blank(pianoTemplate())
        let data = try MSCXEncoder.encode(score)
        let reparsed = try MSCXParser.parse(data)
        // `source` is loader-set metadata (which file format we read), not score content — see
        // `Score.withSource(_:)` in MSCXRoundTripTests.swift, whose doc comment makes the same call for the
        // package's other round-trip suite. `Score.blank(_:)` reports `.unknown` (programmatic construction);
        // re-parsing the encoded bytes necessarily reports `.museScore(.v4)` since mscx carries no such field.
        #expect(reparsed.withSource(.unknown) == score.withSource(.unknown))
    }

    // MARK: - Multi-part (v2)

    @Test("multi-part: ids, programs, bracket group, parallel measure chains")
    func multiPartFactoryBuildsPartsBracketsAndPrograms() {
        let template = BlankScoreTemplate(
            title: "Quartet",
            parts: [
                .init(instrumentID: "violin", longName: "Violin", staves: [.init(clefType: "G")], gmProgram: 40),
                .init(instrumentID: "violin", longName: "Violin", staves: [.init(clefType: "G")], gmProgram: 40),
                .init(instrumentID: "viola", longName: "Viola", staves: [.init(clefType: "C3")], gmProgram: 41),
                .init(instrumentID: "violoncello", longName: "Cello", staves: [.init(clefType: "F")], gmProgram: 42),
            ],
            bracketGroups: [0 ..< 4],
            measureCount: 4,
        )
        let score = Score.blank(template)
        #expect(score.parts.count == 4)
        #expect(score.parts.map(\.id) == ["1", "2", "3", "4"])
        #expect(Set(score.parts.map(\.id)).count == 4) // unique part ids
        #expect(score.parts[0].instrument.channel.program == 40)
        #expect(score.parts[3].instrument.channel.program == 42)
        #expect(score.parts[0].instrument.longName == "Violin")
        #expect(score.parts[0].instrument.trackName == "Violin")
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 4)])
        #expect(score.parts[1].staves[0].brackets.isEmpty)
        #expect(score.systemMeasures.count == 4)
        for part in score.parts {
            #expect(part.staves[0].measures.count == 4)
        }
    }

    @Test("a bracket group's span counts staves, not parts, and anchors on the range's first part")
    func bracketGroupSpansStaves() {
        let score = Score.blank(BlankScoreTemplate(
            title: "Mixed",
            parts: [
                .init(instrumentID: "flute", longName: "Flute", staves: [.init(clefType: "G")]),
                .init(
                    instrumentID: "piano",
                    longName: "Piano",
                    staves: [.init(clefType: "G"), .init(clefType: "F")],
                ),
                .init(instrumentID: "cello", longName: "Cello", staves: [.init(clefType: "F")]),
            ],
            bracketGroups: [1 ..< 3],
            measureCount: 2,
        ))
        #expect(score.parts[0].staves[0].brackets.isEmpty)
        // Piano keeps its own brace and additionally anchors the 3-staff group bracket.
        #expect(score.parts[1].staves[0].brackets == [
            BracketItem(type: .brace, span: 2),
            BracketItem(type: .normal, span: 3),
        ])
        #expect(score.parts[2].staves[0].brackets.isEmpty)
    }

    @Test("out-of-bounds or empty bracket ranges are ignored")
    func invalidBracketGroupsAreIgnored() {
        let score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "flute", longName: "Flute", staves: [.init(clefType: "G")]),
                .init(instrumentID: "oboe", longName: "Oboe", staves: [.init(clefType: "G")]),
            ],
            bracketGroups: [0 ..< 0, 1 ..< 5, -1 ..< 1],
            measureCount: 1,
        ))
        for part in score.parts {
            #expect(part.staves[0].brackets.isEmpty)
        }
    }

    @Test("a multi-staff part still gets its brace")
    func grandStaffPartStillGetsBrace() {
        let score = Score.blank(BlankScoreTemplate(
            title: "P",
            parts: [.init(
                instrumentID: "piano",
                longName: "Piano",
                staves: [.init(clefType: "G"), .init(clefType: "F")],
                gmProgram: 0,
            )],
            measureCount: 2,
        ))
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
    }

    @Test("a drum part is a percussion staff wired to the shared GM line map")
    func drumPartIsPercussion() {
        let score = Score.blank(BlankScoreTemplate(
            title: "D",
            parts: [.init(
                instrumentID: "drumset",
                longName: "Drum Kit",
                staves: [.init(clefType: "PERC", isPercussion: true)],
                isDrums: true,
            )],
            concertKey: 3,
            measureCount: 2,
        ))
        #expect(score.parts[0].instrument.useDrumset)
        #expect(score.parts[0].instrument.drumLineMap == GMPercussion.drumLineMap)
        #expect(score.parts[0].staves[0].group == "percussion")
        #expect(score.parts[0].staves[0].staffType == "perc5Line")
        #expect(score.parts[0].staves[0].lineCount == 5)
        // Percussion has no key — the drum staff opens on the time signature alone.
        let first = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(first[0] == .timeSignature(TimeSignature(numerator: 4, denominator: 4)))
        #expect(first[1].isMeasureRest)
    }

    @Test("a transposing part copies its transposition pair onto the instrument")
    func transposingPartCarriesItsPair() {
        let score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(
                instrumentID: "clarinet",
                longName: "Clarinet",
                shortName: "Cl.",
                staves: [.init(clefType: "G")],
                transposeDiatonic: -1,
                transposeChromatic: -2,
                gmProgram: 71,
            )],
            measureCount: 1,
        ))
        #expect(score.parts[0].instrument.transposeDiatonic == -1)
        #expect(score.parts[0].instrument.transposeChromatic == -2)
        #expect(score.parts[0].instrument.shortName == "Cl.")
        #expect(score.parts[0].instrument.isTransposing)
    }

    @Test("a mixed multi-part score round-trips through the mscx encoder semantically")
    func multiPartRoundTripsThroughMSCX() throws {
        let score = Score.blank(BlankScoreTemplate(
            title: "Ensemble", composer: "Me",
            parts: [
                .init(
                    instrumentID: "flute",
                    longName: "Flute",
                    shortName: "Fl.",
                    staves: [.init(clefType: "G")],
                    gmProgram: 73,
                ),
                .init(
                    instrumentID: "clarinet",
                    longName: "Clarinet",
                    shortName: "Cl.",
                    staves: [.init(clefType: "G")],
                    transposeDiatonic: -1,
                    transposeChromatic: -2,
                    gmProgram: 71,
                ),
                .init(
                    instrumentID: "piano",
                    longName: "Piano",
                    shortName: "Pno.",
                    staves: [.init(clefType: "G"), .init(clefType: "F")],
                    gmProgram: 0,
                ),
                .init(
                    instrumentID: "drumset",
                    longName: "Drum Kit",
                    shortName: "D. Kit",
                    staves: [.init(clefType: "PERC", isPercussion: true)],
                    isDrums: true,
                ),
            ],
            bracketGroups: [0 ..< 2],
            concertKey: -2, timeNumerator: 6, timeDenominator: 8,
            tempoBPM: 108, measureCount: 3,
        ))
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        // See `roundTrip()` above for why `source` is normalized away.
        #expect(reparsed.withSource(.unknown) == score.withSource(.unknown))
    }
}
