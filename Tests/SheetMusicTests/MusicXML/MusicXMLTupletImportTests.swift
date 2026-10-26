import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// MusicXML's tuplets become `Voice.tuplets`, grouped and padded as MuseScore's import groups and pads them. The import
/// used to shorten each member by its `<time-modification>` and keep no tuplet, so the page showed no bracket or
/// number, and a MuseScore save wrote the members as bare fractions
/// (`<durationType>measure</durationType><duration>1/12</duration>`), which MuseScore reads as whole notes.
@Suite("MusicXML tuplets")
struct MusicXMLTupletImportTests {
    // MARK: - MuseScore's fixtures

    /// MuseScore's own tuplet fixtures (`src/importexport/musicxml/tests/data/`), each judged against the `.mscx`
    /// MuseScore 4.7.4 wrote from it (`mscore --musicxml-infer-text-type -o`): the notes as `ScoreSemanticComparison`
    /// sees them, and every tuplet's ratio and members. Not its look — MuseScore's import sets the `<tuplet>`'s
    /// `bracket`, `show-number` and `placement` on the tuplet but leaves them styled, so its writer drops them
    /// (`TWrite::writeProperty` skips a styled property); `appearanceFollowsTheTupletMark` covers that instead.
    /// The refs are `mscore` saves like the direction fixtures', so they compare under the same allowances. Not
    /// vendored: `testTwoNoteTremoloTuplet` — the import reads no two-note tremolo, so its members keep the tremolo's
    /// 2:1 in their values where MuseScore gives them their written ones, and its 6:2 tuplet is not MuseScore's 3:2.
    static let tupletFixtures: [String] = [
        "testTuplets1",
        "testTuplets2",
        "testTuplets3",
        "testTuplets4",
        "testTuplets5",
        "testTuplets6",
        "testTuplets7",
        "testTuplets9",
        "testIncompleteTuplet",
        "testTupletTie",
    ]

    /// The fixtures whose notes compare as well — all of them.
    static let noteFixtures = tupletFixtures

    @Test("MuseScore's tuplet fixtures group their tuplets as MuseScore does", arguments: tupletFixtures)
    func tupletsMatchMuseScore(_ fixture: String) throws {
        let produced = try MusicXMLParser.parse(MusicXMLFixtureLoader.xml(fixture))
        let reference = try MSCXParser.parse(MusicXMLFixtureLoader.referenceMscx(fixture))
        #expect(Self.tupletSummary(produced) == Self.tupletSummary(reference))
    }

    @Test("MuseScore's tuplet fixtures import the notes MuseScore reads", arguments: noteFixtures)
    func notesMatchMuseScore(_ fixture: String) throws {
        let produced = try MusicXMLParser.parse(MusicXMLFixtureLoader.xml(fixture))
        let reference = try MSCXParser.parse(MusicXMLFixtureLoader.referenceMscx(fixture))
        ScoreSemanticComparison.assertEquivalent(
            produced: Self.withoutStringData(produced), reference: Self.withoutStringData(reference),
            options: MusicXMLImportTests.directionOptions,
        )
    }

    /// The parts' strings cleared: MuseScore gives a part it recognizes as a guitar (testTuplets1) its instrument
    /// template's strings, which MusicXML does not carry — template data, like the fields
    /// `ignoreInstrumentPlaybackFields` clears.
    private static func withoutStringData(_ score: Score) -> Score {
        var cleared = score
        cleared.parts.mapValues { part in
            var stringless = part
            stringless.instrument.stringData = nil
            return stringless
        }
        return cleared
    }

    /// Every tuplet as `staff/measure/voice normal:actual first...last`, its ends counted in chords and rests so the
    /// annotations either side may hold in between do not move them.
    private static func tupletSummary(_ score: Score) -> [String] {
        score.allStaves.enumerated().flatMap { staffIndex, entry in
            entry.staff.measures.enumerated().flatMap { measureIndex, measure in
                measure.voices.enumerated().flatMap { voiceIndex, voice in
                    voice.tupletSpans.map { span in
                        let first = chordOrdinal(voice, span.startIndex)
                        let last = chordOrdinal(voice, span.endIndex)
                        return "\(staffIndex)/\(measureIndex)/\(voiceIndex) \(span.normalNotes):\(span.actualNotes) "
                            + "\(first)...\(last)"
                    }
                }
            }
        }
    }

    private static func chordOrdinal(_ voice: Voice, _ index: Int) -> Int {
        voice.elements.values.prefix(index).count { if case .chord = $0 { true } else { false } }
    }

    // MARK: - Grouping

    @Test("A marked triplet is one tuplet over its three notes, and takes its look from the start mark")
    func appearanceFollowsTheTupletMark() throws {
        let start = #"<tuplet type="start" bracket="yes" show-number="both" placement="below"/>"#
        let voice = try Self.firstVoice(Self.part([
            Self.note("eighth", 2, modification: (3, 2), tuplet: start),
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("eighth", 2, modification: (3, 2), tuplet: #"<tuplet type="stop"/>"#),
            Self.note("quarter", 6), Self.note("quarter", 6), Self.note("quarter", 6),
        ]))
        #expect(Self.spans(voice) == ["2:3 0...2"])
        let appearance = try #require(voice.tuplets.values.first).appearance
        #expect(appearance.bracketType == .bracket)
        #expect(appearance.numberType == .ratio)
        #expect(appearance.direction == .down)
    }

    @Test("Without marks, a run of modified notes splits into tuplets as each fills up")
    func unmarkedTupletsCloseWhenFull() throws {
        let triplet = Array(repeating: Self.note("eighth", 2, modification: (3, 2)), count: 6)
        let voice = try Self.firstVoice(Self.part(triplet + [Self.note("half", 12)]))
        #expect(Self.spans(voice) == ["2:3 0...2", "2:3 3...5"])
        #expect(voice.tuplets.values.allSatisfy { $0.appearance == TupletAppearance() })
    }

    @Test("<normal-type> sets how much fills an unmarked tuplet; without it, the smallest member's value does")
    func normalTypeDecidesFullness() throws {
        let eighthUnit = "<normal-type>eighth</normal-type>"
        let voice = try Self.firstVoice(Self.part(time: (3, 4), [
            Self.note("16th", 1, modification: (3, 2), extra: eighthUnit),
            Self.note("eighth", 2, modification: (3, 2), extra: eighthUnit),
            Self.note("eighth", 2, modification: (3, 2), extra: eighthUnit),
            Self.note("16th", 1, modification: (3, 2), extra: eighthUnit),
            Self.note("quarter", 4, modification: (3, 2)),
            Self.note("quarter", 4, modification: (3, 2)),
            Self.note("quarter", 4, modification: (3, 2)),
        ]))
        #expect(Self.spans(voice) == ["2:3 0...3", "2:3 4...6"])
    }

    @Test("A sextuplet keeps 6:4 rather than its reduced 3:2")
    func sextupletKeepsItsRatio() throws {
        var notes = (0 ..< 6).map { index in
            Self.note(
                "16th", 1, modification: (6, 4),
                tuplet: index == 0 ? #"<tuplet type="start"/>"# : index == 5 ? #"<tuplet type="stop"/>"# : nil,
            )
        }
        notes += [Self.note("quarter", 6), Self.note("half", 12)]
        let voice = try Self.firstVoice(Self.part(notes))
        #expect(Self.spans(voice) == ["4:6 0...5"])
    }

    @Test("A chord tone joins its chord, not the tuplet's count, and a dynamic in between leaves its ends in place")
    func chordTonesAndDirectionsLeaveTheEndsInPlace() throws {
        let dynamic = """
        <direction placement="below"><direction-type><dynamics><f/></dynamics></direction-type></direction>
        """
        let voice = try Self.firstVoice(Self.part([
            Self.note("eighth", 2, step: "C", modification: (3, 2), tuplet: #"<tuplet type="start"/>"#),
            dynamic,
            Self.note("eighth", 2, step: "D", modification: (3, 2)),
            Self.note("eighth", 2, step: "F", modification: (3, 2), chordTone: true),
            Self.note("eighth", 2, step: "E", modification: (3, 2), tuplet: #"<tuplet type="stop"/>"#),
            Self.note("quarter", 6), Self.note("half", 12),
        ]))
        #expect(voice.elements.values.contains { if case .dynamic = $0 { true } else { false } })
        let span = try #require(voice.tupletSpans.first)
        #expect(voice.tupletSpans.count == 1)
        #expect(Self.pitches(voice.elements[span.startIndex]) == [60])
        #expect(Self.pitches(voice.elements[span.endIndex]) == [64])
    }

    @Test("A two-note tremolo's 2:1 is no tuplet, as MuseScore keeps it out of one")
    func tremoloModificationIsNoTuplet() throws {
        let voice = try Self.firstVoice(Self.part([
            Self.note("half", 6, modification: (2, 1)),
            Self.note("half", 6, modification: (2, 1)),
            Self.note("half", 12),
        ]))
        #expect(voice.tuplets.isEmpty)
    }

    @Test("A note whose time is not modified stops a tuplet its stop mark never reached")
    func aPlainNoteStopsAnOpenTuplet() throws {
        let voice = try Self.firstVoice(Self.part([
            Self.note("eighth", 2, modification: (3, 2), tuplet: #"<tuplet type="start"/>"#),
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("quarter", 6), Self.note("half", 12),
        ]))
        #expect(Self.spans(voice) == ["2:3 0...2"])
    }

    @Test("A tuplet a plain note stops short is padded with a rest, as MuseScore pads it, and the note follows it")
    func aShortTupletIsPadded() throws {
        let voice = try Self.firstVoice(Self.part([
            Self.note("eighth", 2, modification: (3, 2), tuplet: #"<tuplet type="start"/>"#),
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("quarter", 6), Self.note("quarter", 6), Self.note("quarter", 6),
        ]))
        #expect(Self.spans(voice) == ["2:3 0...2"])
        #expect(Self.durations(voice) == [12, 12, 12, 4, 4, 4].map { Fraction(numerator: 1, denominator: $0) })
        let span = try #require(voice.tupletSpans.first)
        #expect(Self.pitches(voice.elements[span.endIndex]).isEmpty)
    }

    @Test("A tuplet the bar line leaves short is padded after its last note")
    func aTupletShortAtTheBarLineIsPadded() throws {
        let voice = try Self.firstVoice(Self.part([
            Self.note("quarter", 6), Self.note("quarter", 6), Self.note("quarter", 6),
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("eighth", 2, modification: (3, 2)),
        ]))
        #expect(Self.spans(voice) == ["2:3 3...5"])
        #expect(Self.durations(voice).suffix(3) == Array(repeating: Fraction(numerator: 1, denominator: 12), count: 3))
    }

    @Test("Padding completes a tuplet to the next whole value of its length (missingTupletDuration)")
    func paddingCompletesTheLength() {
        let pad = { (numerator: Int, denominator: Int) in
            MusicXMLTupletTracker.padding(after: Fraction(numerator: numerator, denominator: denominator))
        }
        // Two of a quarter triplet's thirds leave a sixth; eight of a 9:8's ninths a 1/18; a full one nothing.
        #expect(pad(1, 3) == Fraction(numerator: 1, denominator: 6))
        #expect(pad(4, 9) == Fraction(numerator: 1, denominator: 18))
        #expect(pad(1, 4) == .zeroTick)
        #expect(pad(3, 4) == .zeroTick)
    }

    @Test("A rest two thirds as long as its type says opens a triplet, as Encore writes one, and keeps its length")
    func unmarkedTripletRest() throws {
        let rest = "<note><rest/><duration>2</duration><voice>1</voice><type>eighth</type></note>"
        let voice = try Self.firstVoice(Self.part([
            rest,
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("quarter", 6), Self.note("half", 12),
        ]))
        #expect(Self.spans(voice) == ["2:3 0...2"])
        let span = try #require(voice.tupletSpans.first)
        guard case let .chord(first) = voice.elements[span.startIndex] else {
            Issue.record("the tuplet does not open on the rest")
            return
        }
        #expect(first.duration == .fraction(Fraction(numerator: 1, denominator: 12)))
    }

    @Test("A tuplet still open at the bar line stops there")
    func theMeasureEndStopsATuplet() throws {
        let marked = (0 ..< 3).map { index in
            Self.note("half", 8, modification: (3, 2), tuplet: index == 0 ? #"<tuplet type="start"/>"# : nil)
        }
        let score = try MusicXMLParser.parse(Self.document(measures: [marked, [Self.note("whole", 24)]]))
        let measures = score.parts[0].staves[0].measures
        #expect(Self.spans(measures[0].voices[0]) == ["2:3 0...2"])
        #expect(measures[1].voices[0].tuplets.isEmpty)
    }

    // MARK: - Saving for MuseScore

    @Test("A MuseScore save writes the tuplet and its members' own values, and reads back the same tuplet")
    func mscxSaveWritesTheTuplet() throws {
        let score = try MusicXMLParser.parse(Self.part([
            Self.note("eighth", 2, modification: (3, 2), tuplet: #"<tuplet type="start"/>"#),
            Self.note("eighth", 2, modification: (3, 2)),
            Self.note("eighth", 2, modification: (3, 2), tuplet: #"<tuplet type="stop"/>"#),
            Self.note("quarter", 6), Self.note("half", 12),
        ]))
        let data = try MSCXEncoder.encode(score)
        let xml = try #require(String(data: data, encoding: .utf8))
        #expect(xml.contains("<baseNote>eighth</baseNote>"))
        #expect(!xml.contains("<durationType>measure</durationType>"))
        let reread = try MSCXParser.parse(data)
        #expect(Self.spans(reread.parts[0].staves[0].measures[0].voices[0]) == ["2:3 0...2"])
    }

    // MARK: - Helpers

    private static func firstVoice(_ data: Data) throws -> Voice {
        try MusicXMLParser.parse(data).parts[0].staves[0].measures[0].voices[0]
    }

    /// Each tuplet as `normal:actual first...last`, its ends counted in chords and rests.
    private static func spans(_ voice: Voice) -> [String] {
        voice.tupletSpans.map { span in
            let first = chordOrdinal(voice, span.startIndex)
            let last = chordOrdinal(voice, span.endIndex)
            return "\(span.normalNotes):\(span.actualNotes) \(first)...\(last)"
        }
    }

    /// The voice's chords' and rests' values, as fractions of a whole note.
    private static func durations(_ voice: Voice) -> [Fraction] {
        voice.elements.values.compactMap { element in
            guard case let .chord(chord) = element else { return nil }
            return chord.duration.asFraction
        }
    }

    private static func pitches(_ element: VoiceElement) -> [Int] {
        guard case let .chord(chord) = element else { return [] }
        return chord.notes.map(\.pitch)
    }

    /// One `<note>` at `divisions` 6 to the quarter: `modification` is `(actual, normal)`, `tuplet` the `<tuplet>`
    /// mark and `extra` more `<time-modification>` children.
    private static func note(
        _ type: String, _ duration: Int, step: String = "C", modification: (Int, Int)? = nil, tuplet: String? = nil,
        extra: String = "", chordTone: Bool = false,
    ) -> String {
        let timeModification = modification.map { actual, normal in
            "<time-modification><actual-notes>\(actual)</actual-notes><normal-notes>\(normal)</normal-notes>"
                + "\(extra)</time-modification>"
        } ?? ""
        let notations = tuplet.map { "<notations>\($0)</notations>" } ?? ""
        return """
        <note>\(chordTone ? "<chord/>" : "")<pitch><step>\(step)</step><octave>4</octave></pitch>\
        <duration>\(duration)</duration><voice>1</voice><type>\(type)</type>\(timeModification)\(notations)</note>
        """
    }

    private static func part(time: (Int, Int) = (4, 4), _ notes: [String]) -> Data {
        document(time: time, measures: [notes])
    }

    private static func document(time: (Int, Int) = (4, 4), measures: [[String]]) -> Data {
        let body = measures.enumerated().map { index, notes in
            let attributes = index == 0 ? """
            <attributes><divisions>6</divisions><time><beats>\(time.0)</beats><beat-type>\(time.1)</beat-type></time>\
            <clef><sign>G</sign><line>2</line></clef></attributes>
            """ : ""
            return #"<measure number="\#(index + 1)">"# + attributes + notes.joined() + "</measure>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
          <part id="P1">\(body)</part>
        </score-partwise>
        """.utf8)
    }
}
