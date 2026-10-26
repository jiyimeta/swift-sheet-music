import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

/// What MuseScore's importer adds to a part's shape that the file does not spell out: the implicit brace of a
/// multi-staff part (`P1:1483-1499`), the explicit normal bar line closing the score (`P2:2109-2118`) and the length
/// of a bar that is not its time signature's (`P1:453-480`).
@Suite("MusicXML part shape")
struct MusicXMLPartShapeTests {
    private typealias F = DirectionFixtures

    private static func score(partList: String, measures: String, staves: Int) throws -> Score {
        let stavesTag = staves > 1 ? "<staves>\(staves)</staves>" : ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0"><part-list>\(partList)</part-list>\
        <part id="P1"><measure number="1"><attributes><divisions>480</divisions>\(stavesTag)</attributes>\
        \(measures)</measure></part></score-partwise>
        """
        return try MusicXMLParser.parse(Data(xml.utf8))
    }

    private static let piano = "<score-part id=\"P1\"><part-name>Piano</part-name></score-part>"

    /// MuseScore numbers the brace's column 1 (`bracketLevels + 1`) and draws the empty column 0 at no width; ssm's
    /// gutter gives every column a spatium, so the import compacts the columns and the lone brace sits in column 0.
    @Test("a two-staff part with no part-group gets a brace on its first staff, in column 0")
    func implicitBrace() throws {
        let score = try F.score(measures: [F.whole("C", staff: 1) + "<backup><duration>1920</duration></backup>"
                + F.whole("C", octave: 3, staff: 2)], staves: 2)
        let staves = score.parts[0].staves
        #expect(staves[0].brackets == [BracketItem(type: .brace, span: 2, column: 0)])
        #expect(staves[1].brackets.isEmpty)
    }

    @Test("compacting keeps the columns' order and closes only the gaps")
    func compactedColumns() {
        func staff(_ columns: [Int]) -> Staff {
            Staff(brackets: columns.map { BracketItem(type: .normal, span: 1, column: $0) })
        }
        let parts = [
            Part(id: "1", instrument: Instrument(id: "x"), staves: [staff([1, 3])]),
            Part(id: "2", instrument: Instrument(id: "x"), staves: [staff([3])]),
        ]
        let compacted = Score.canonicalizingBracketColumns(parts)
        #expect(compacted[0].staves[0].brackets.map(\.column) == [0, 1])
        #expect(compacted[1].staves[0].brackets.map(\.column) == [1])
    }

    @Test("a one-staff part gets no brace")
    func noBraceOnOneStaff() throws {
        let score = try F.score(measures: [F.fourQuarters])
        #expect(score.parts[0].staves[0].brackets.isEmpty)
    }

    @Test("a part-group bracketing the part alone replaces the implicit brace; one of a wider span does not")
    func explicitGroup() throws {
        let alone = "<part-group type=\"start\" number=\"1\"><group-symbol>bracket</group-symbol></part-group>"
            + Self.piano + "<part-group type=\"stop\" number=\"1\"/>"
        let notes = F.whole("C", staff: 1)
        #expect(try Self.score(partList: alone, measures: notes, staves: 2).parts[0].staves[0].brackets.isEmpty)
        let noSymbol = "<part-group type=\"start\" number=\"1\"><group-symbol>none</group-symbol></part-group>"
            + Self.piano + "<part-group type=\"stop\" number=\"1\"/>"
        let braced = try Self.score(partList: noSymbol, measures: notes, staves: 2).parts[0].staves[0].brackets
        #expect(braced == [BracketItem(type: .brace, span: 2, column: 0)])
    }

    @Test("groups starting at the part push the brace one column past theirs")
    func braceColumnAfterGroups() throws {
        let list = """
        <part-list><part-group type="start" number="2"><group-symbol>bracket</group-symbol></part-group>\
        <score-part id="P1"/><score-part id="P2"/><part-group type="stop" number="2"/></part-list>
        """
        let groups = try MusicXMLPartGroups(partList: XMLTreeParser.parse(Data(list.utf8)))
        #expect(groups.impliedBraceColumn(partIndex: 0, staffCount: 2) == 2)
        #expect(groups.impliedBraceColumn(partIndex: 1, staffCount: 2) == 1)
        #expect(groups.impliedBraceColumn(partIndex: 0, staffCount: 1) == nil)
    }

    private static func lastElement(_ score: Score) -> VoiceElement? {
        score.parts[0].staves[0].measures.last?.voices[0].elements.values.last
    }

    @Test("a score that ends without a bar line gets MuseScore's explicit normal one")
    func finalNormalBarLine() throws {
        let score = try F.score(measures: [F.fourQuarters, F.fourQuarters])
        #expect(Self.lastElement(score) == .barLine(BarLine()))
        let first = score.parts[0].staves[0].measures[0].voices[0].elements.values.last
        #expect(first.map { element in if case .chord = element { true } else { false } } == true)
    }

    @Test("a styled final bar line or an end repeat is left as it is")
    func styledFinalBarLine() throws {
        let end = "<barline location=\"right\"><bar-style>light-heavy</bar-style></barline>"
        #expect(try Self.lastElement(F.score(measures: [F.fourQuarters + end])) == .barLine(BarLine(subtype: "end")))
        let repeatEnd = "<barline location=\"right\"><repeat direction=\"backward\"/></barline>"
        let repeated = try F.score(measures: [F.fourQuarters + repeatEnd])
        let last = Self.lastElement(repeated)
        #expect(last.map { element in if case .barLine = element { true } else { false } } != true)
    }

    // MARK: - Bar lines and repeats

    private static func barline(
        _ style: String?,
        repeat direction: String? = nil,
        location: String = "right",
        times: String? = nil,
    ) -> String {
        let styleTag = style.map { "<bar-style>\($0)</bar-style>" } ?? ""
        let repeatTag = direction.map { direction in
            "<repeat direction=\"\(direction)\"\(times.map { " times=\"\($0)\"" } ?? "")/>"
        } ?? ""
        return "<barline location=\"\(location)\">\(styleTag)\(repeatTag)</barline>"
    }

    private static func barLines(in voice: Voice) -> [BarLine] {
        voice.elements.values.compactMap { element in
            if case let .barLine(line) = element { line } else { nil }
        }
    }

    /// Two halves in voice 1, then two in voice 2 after a backup, `between` written after voice 2's first half.
    private static func twoVoices(between: String = "") -> String {
        F.half("C") + F.half("D") + "<backup><duration>1920</duration></backup>"
            + F.half("E", octave: 3, voice: 2) + between + F.half("F", octave: 3, voice: 2)
    }

    @Test("the end bar line goes into the first voice, whichever voice wrote the last note")
    func endBarLineInTheFirstVoice() throws {
        let score = try F.score(measures: [Self.twoVoices() + Self.barline("light-light")])
        let measure = score.parts[0].staves[0].measures[0]
        #expect(Self.barLines(in: measure.voices[0]) == [BarLine(subtype: "double")])
        #expect(Self.barLines(in: measure.voices[1]).isEmpty)
    }

    @Test("a bar line inside the measure goes into the first voice at its tick")
    func middleBarLineAtItsTick() throws {
        let score = try F.score(measures: [Self.twoVoices(between: Self.barline("dashed", location: "middle"))])
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        let kinds = voice.elements.values.map { element -> String in
            switch element {
            case .chord: "chord"
            case let .barLine(line): line.subtype ?? "normal"
            default: "other"
            }
        }
        // The score's closing normal bar line follows.
        #expect(kinds.filter { $0 != "other" } == ["chord", "dashed", "chord", "normal"])
        #expect(Self.barLines(in: score.parts[0].staves[0].measures[0].voices[1]).isEmpty)
    }

    @Test("a light-heavy backward repeat ends the repeat and draws no bar line of its own; times is the count")
    func endRepeatIsAFlag() throws {
        let end = Self.barline("light-heavy", repeat: "backward", times: "3")
        let measure = try F.score(measures: [F.fourQuarters + end]).parts[0].staves[0].measures[0]
        #expect(measure.endRepeatCount == 3)
        #expect(Self.barLines(in: measure.voices[0]).isEmpty)
    }

    @Test("a repeat in another style is that style's bar line and repeats nothing, as in MuseScore")
    func otherStyleWithRepeatIsALine() throws {
        let score = try F.score(measures: [F.fourQuarters + Self.barline("light-light", repeat: "backward")])
        let measure = score.parts[0].staves[0].measures[0]
        #expect(measure.endRepeatCount == nil)
        #expect(Self.barLines(in: measure.voices[0]) == [BarLine(subtype: "double")])
    }

    @Test("a heavy-heavy bar line is MuseScore's double-heavy")
    func heavyHeavyIsDoubleHeavy() throws {
        let score = try F.score(measures: [F.fourQuarters + Self.barline("heavy-heavy")])
        #expect(Self.barLines(in: score.parts[0].staves[0].measures[0].voices[0]) == [BarLine(subtype: "double-heavy")])
    }

    private static func spanned(from: Int, to: Int) -> BarLine {
        BarLine(preservedMarkup: [
            PreservedXML(name: "spanFromOffset", text: String(from)),
            PreservedXML(name: "spanToOffset", text: String(to)),
        ])
    }

    @Test("none is a hidden normal bar line; tick and short are normal ones with MuseScore's span offsets")
    func hiddenAndPartialBarLines() throws {
        let cases: [(style: String, line: BarLine)] = [
            ("none", BarLine(visible: false)),
            ("tick", Self.spanned(from: -1, to: -7)),
            ("short", Self.spanned(from: 2, to: -2)),
        ]
        for entry in cases {
            let score = try F.score(measures: [F.fourQuarters + Self.barline(entry.style), F.fourQuarters])
            #expect(Self.barLines(in: score.parts[0].staves[0].measures[0].voices[0]) == [entry.line], "\(entry.style)")
        }
    }

    @Test("a score ending on a hidden, tick or short bar line ends on a plain one, as MuseScore's import ends it")
    func normalFinalBarLineIsReplaced() throws {
        for style in ["none", "tick", "short"] {
            let score = try F.score(parts: [[F.fourQuarters + Self.barline(style)], [F.fourQuarters]])
            for part in score.parts {
                #expect(Self.barLines(in: part.staves[0].measures[0].voices[0]) == [BarLine()], "\(style)")
            }
        }
    }

    @Test("repeats sit on the score's first staff alone, whichever part wrote them")
    func repeatsOnTheFirstStaff() throws {
        let start = Self.barline("heavy-light", repeat: "forward", location: "left")
        let end = Self.barline(nil, repeat: "backward")
        let score = try F.score(parts: [[F.fourQuarters], [start + F.fourQuarters + end]])
        let first = score.parts[0].staves[0].measures[0]
        #expect(first.startRepeat)
        #expect(first.endRepeatCount == 2)
        let second = score.parts[1].staves[0].measures[0]
        #expect(!second.startRepeat)
        #expect(second.endRepeatCount == nil)
    }

    // MARK: - Measure length

    private static let threeQuarters = ["C", "D", "E"].map { F.quarter($0) }.joined()

    private static func lengths(_ score: Score, part: Int = 0) -> [Fraction?] {
        score.parts[part].staves[0].measures.map(\.actualLength)
    }

    @Test("a bar shorter than its time signature keeps its length, as MuseScore's len; a full bar has none")
    func shortBarKeepsItsLength() throws {
        let score = try F.score(measures: [F.fourQuarters, Self.threeQuarters, F.fourQuarters])
        #expect(Self.lengths(score) == [nil, Fraction(numerator: 3, denominator: 4), nil])
    }

    @Test("a bar is as long as its longest part, in every part")
    func longestPartSetsTheLength() throws {
        let score = try F.score(parts: [
            [Self.threeQuarters, Self.threeQuarters],
            [F.fourQuarters, Self.threeQuarters],
        ])
        let short = Fraction(numerator: 3, denominator: 4)
        #expect(Self.lengths(score, part: 0) == [nil, short])
        #expect(Self.lengths(score, part: 1) == [nil, short])
    }

    @Test("notes whose <duration> falls short of their <type> fill the bar their types fill (checkTiming)")
    func typesNotDurationsMeasureTheBar() throws {
        let sloppy = ["C", "D", "E", "F"].map { F.note($0, duration: 470, type: "quarter") }.joined()
        let score = try F.score(measures: [sloppy])
        #expect(Self.lengths(score) == [nil])
    }

    @Test("a length that is no whole number of 128ths rounds up to the next one")
    func lengthRoundsToWhole128ths() throws {
        // 100 of 1920 divisions to the whole is 5/96, between 6/128 and 7/128 by more than a division.
        let score = try F.score(measures: ["<forward><duration>100</duration></forward>"])
        #expect(Self.lengths(score) == [Fraction(numerator: 7, denominator: 128)])
    }

    @Test("a measure one part calls implicit is left out of the bar numbers in every part (setIrregular)")
    func implicitMeasureIsIrregular() throws {
        let measures = [F.quarter("G"), F.fourQuarters]
        let document = try #require(String(bytes: F.data(parts: [(measures, 1), (measures, 1)]), encoding: .utf8))
        // Only the first part's pickup says so.
        let first = try #require(document.range(of: "<measure number=\"1\">"))
        let marked = document.replacingCharacters(in: first, with: "<measure number=\"0\" implicit=\"yes\">")
        let score = try MusicXMLParser.parse(Data(marked.utf8))
        #expect(score.parts.map { $0.staves[0].measures.map(\.irregular) } == [[true, false], [true, false]])
        #expect([0, 1].map(score.displayedMeasureNumber(at:)) == [nil, 1])
    }

    @Test("implicit=\"no\" and no implicit leave a measure regular")
    func explicitMeasureIsRegular() throws {
        let document = try #require(String(bytes: F.data(parts: [([F.fourQuarters], 1)]), encoding: .utf8))
        let marked = document.replacingOccurrences(
            of: "<measure number=\"1\">", with: "<measure number=\"1\" implicit=\"no\">",
        )
        let score = try MusicXMLParser.parse(Data(marked.utf8))
        #expect(score.parts[0].staves[0].measures.map(\.irregular) == [false])
    }

    @Test("an <encoding><encoder> is MuseScore's encoder meta tag (testSibOttavas)")
    func encoderMetaTag() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0"><identification><encoding>\
        <encoder>James Mizen</encoder></encoding></identification><part-list>\(Self.piano)</part-list>\
        <part id="P1"><measure number="1"><attributes><divisions>480</divisions></attributes>\
        \(F.whole("C"))</measure></part></score-partwise>
        """
        #expect(try MusicXMLParser.parse(Data(xml.utf8)).metaTags["encoder"] == "James Mizen")
    }
}
