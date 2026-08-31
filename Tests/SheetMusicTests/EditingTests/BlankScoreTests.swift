import Foundation
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
        // Piano keeps its own brace and additionally anchors the 3-staff group bracket. The group bracket
        // takes column 1: at column 0 its spine (`staffOriginX - 0.5 sp`) would be drawn inside the brace
        // glyph, whose right edge sits at `staffOriginX - 0.3 sp`.
        #expect(score.parts[1].staves[0].brackets == [
            BracketItem(type: .brace, span: 2),
            BracketItem(type: .normal, span: 3, column: 1),
        ])
        #expect(score.parts[1].staves[0].brackets[1].column == 1)
        #expect(score.parts[2].staves[0].brackets.isEmpty)
    }

    /// A group headed by a single-staff part has nothing to nest under, so its bracket stays in column 0.
    @Test("a group bracket with no brace under it stays in column 0")
    func bracketGroupWithoutBraceUsesColumnZero() {
        let score = Score.blank(BlankScoreTemplate(
            title: "SA",
            parts: [
                .init(instrumentID: "voice", longName: "Soprano", staves: [.init(clefType: "G")]),
                .init(instrumentID: "voice", longName: "Alto", staves: [.init(clefType: "G")]),
            ],
            bracketGroups: [0 ..< 2],
            measureCount: 1,
        ))
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 2, column: 0)])
    }

    /// The percussion staff's key-signature strip removes elements a tuplet's `startIndex`/`endIndex` index
    /// into, so the endpoints have to move with them. `Score.blank(_:)` never builds a tuplet, but
    /// `Part.init(blankPlan:id:measures:)` takes any bar chain — an add-part command hands it real bars.
    @Test("stripping a drum staff's key signature remaps tuplet spans")
    func percussionStripRemapsTupletSpans() {
        let triplet = [
            VoiceElement.chord(Chord(duration: .eighth, notes: [Note(pitch: 38, tpc: 16)])),
            .chord(Chord(duration: .eighth, notes: [Note(pitch: 38, tpc: 16)])),
            .chord(Chord(duration: .eighth, notes: [Note(pitch: 38, tpc: 16)])),
        ]
        let bar = Measure(voices: [Voice(
            elements: [
                .keySignature(KeySignature(concertKey: 3)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            ] + triplet,
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)],
        )])
        let part = Part(
            blankPlan: .init(
                instrumentID: "drumset",
                longName: "Drum Kit",
                staves: [.init(clefType: "PERC", isPercussion: true)],
                isDrums: true,
            ),
            id: "1",
            measures: [bar],
        )
        let voice = part.staves[0].measures[0].voices[0]
        #expect(voice.elements.count == 4) // key signature gone, time signature + 3 chords left
        #expect(voice.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)])
        // The endpoints still name the first and last member of the same triplet.
        #expect(voice.elements[voice.tuplets[0].startIndex] == triplet[0])
        #expect(voice.elements[voice.tuplets[0].endIndex] == triplet[2])
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

    // MARK: - Pickup (anacrusis)

    /// A grand-staff part next to two single-staff ones, so "every staff" is four bar-0s spread over both
    /// measure chains the factory builds — the pitched one and the key-stripped percussion copy.
    private func pickupEnsembleTemplate(
        pickup: Fraction?, measures: Int = 4,
    ) -> BlankScoreTemplate {
        BlankScoreTemplate(
            title: "Anacrusis",
            parts: [
                .init(instrumentID: "flute", longName: "Flute", staves: [.init(clefType: "G")], gmProgram: 73),
                .init(
                    instrumentID: "piano", longName: "Piano",
                    staves: [.init(clefType: "G"), .init(clefType: "F")],
                ),
                .init(
                    instrumentID: "drumset", longName: "Drum Kit",
                    staves: [.init(clefType: "PERC", isPercussion: true)], isDrums: true,
                ),
            ],
            concertKey: 2, timeNumerator: 3, timeDenominator: 4,
            tempoBPM: 90, measureCount: measures, pickup: pickup,
        )
    }

    @Test("a pickup makes bar 0 of every staff irregular and touches no other bar")
    func pickupMarksEveryStaffsFirstBar() {
        let quarter = Fraction(numerator: 1, denominator: 4)
        let score = Score.blank(pickupEnsembleTemplate(pickup: quarter))
        let staves = score.parts.flatMap(\.staves)
        #expect(staves.count == 4)
        for staff in staves {
            // `measureCount` counts total bars, the pickup included — asking for 4 gets 4, not 5.
            #expect(staff.measures.count == 4)
            #expect(staff.measures[0].actualLength == quarter)
            #expect(staff.measures[0].irregular)
            // Content is untouched: the bar still holds exactly one measure rest, which now resolves
            // against `actualLength` instead of the 3/4 nominal.
            #expect(staff.measures[0].voices[0].elements.last?.isMeasureRest == true)
            #expect(staff.measures[0].voices[0].elements.filter(\.isMeasureRest).count == 1)
            for measure in staff.measures.dropFirst() {
                #expect(measure.actualLength == nil)
                #expect(!measure.irregular)
                #expect(measure.voices[0].elements == [.rest(duration: .measure)])
            }
        }
        // Signatures stay on measure 0 as before — key + time on a pitched staff, time alone on the drum one.
        let pitchedFirst = staves[0].measures[0].voices[0].elements
        #expect(pitchedFirst[0] == .keySignature(KeySignature(concertKey: 2)))
        #expect(pitchedFirst[1] == .timeSignature(TimeSignature(numerator: 3, denominator: 4)))
        let drumFirst = staves[3].measures[0].voices[0].elements
        #expect(drumFirst[0] == .timeSignature(TimeSignature(numerator: 3, denominator: 4)))
        // The measure rest in bar 0 is a quarter long; every later bar keeps the nominal 3/4.
        let threeFour = Fraction(numerator: 3, denominator: 4)
        #expect(score.effectiveMeasureDurations() == [quarter, threeFour, threeFour, threeFour])
    }

    @Test("the pickup is skipped by the displayed measure numbering")
    func pickupIsExcludedFromDisplayedMeasureNumbers() {
        let score = Score.blank(pickupEnsembleTemplate(pickup: Fraction(numerator: 1, denominator: 8)))
        #expect(score.displayedMeasureNumber(at: 0) == nil)
        #expect(score.displayedMeasureNumber(at: 1) == 1)
        #expect(score.displayedMeasureNumber(at: 2) == 2)
        #expect(score.displayedMeasureNumber(at: 3) == 3)
    }

    @Test("a pickup template round-trips through mscx, len attribute and all")
    func pickupRoundTripsThroughMSCX() throws {
        let quarter = Fraction(numerator: 1, denominator: 4)
        let score = Score.blank(pickupEnsembleTemplate(pickup: quarter))
        let data = try MSCXEncoder.encode(score)
        let xml = try #require(String(bytes: data, encoding: .utf8))
        #expect(xml.contains(#"len="1/4""#))
        #expect(xml.contains("<irregular>1</irregular>"))
        let reparsed = try MSCXParser.parse(data)
        // See `roundTrip()` above for why `source` is normalized away.
        #expect(reparsed.withSource(.unknown) == score.withSource(.unknown))
        for staff in reparsed.parts.flatMap(\.staves) {
            #expect(staff.measures[0].actualLength == quarter)
            #expect(staff.measures[0].irregular)
            #expect(staff.measures.dropFirst().allSatisfy { $0.actualLength == nil && !$0.irregular })
        }
    }

    /// Regression pin on the default. The expected chain below is the one the factory built before the
    /// option existed, written out by hand, so it stays an independent statement of "unchanged" rather
    /// than a mirror of whatever the factory now does. The encoded bytes must likewise carry neither of
    /// the two markers a pickup introduces.
    @Test("a template naming no pickup builds exactly what the pre-pickup factory built")
    func nilPickupMatchesThePrePickupShape() throws {
        let score = Score.blank(pianoTemplate())
        let firstMeasure = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: 2)),
            .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
            .rest(duration: .measure),
        ])])
        let laterMeasure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        let expected = [firstMeasure] + Array(repeating: laterMeasure, count: 3)
        for staff in score.parts.flatMap(\.staves) {
            #expect(staff.measures == expected)
        }
        let xml = try #require(String(bytes: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(!xml.contains("len="))
        #expect(!xml.contains("<irregular>"))
        // Spelling the default out changes nothing.
        var explicitNil = pianoTemplate()
        explicitNil.pickup = nil
        #expect(Score.blank(explicitNil) == score)
    }
}
