import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Foundation declares one too off Apple; the layout's is the one its elements carry.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// MuseScore's "hide empty staves": a system leaves out the staves the score asks to hide while they are empty in it
/// (`SystemLayout::hideEmptyStaves`, `rendering/score/systemlayout.cpp:545-742`). The decision is
/// `LayoutEngine.shownStaves(score:measureRange:isFirstSystem:)`; the layout compacts the hidden staves out of the
/// system's staff arrays while every staff keeps its score-wide address.
@Suite("Hide empty staves")
struct EmptyStaffHidingTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - Fixtures

    /// One bar of one staff.
    enum Bar {
        case rest, note, dynamic, hiddenDynamic, harmony, fermataRest, measureRepeat
        /// A whole note starting a slur that ends two bars later.
        case slurredNote
        /// A rest under a hairpin reaching `bars` barlines on (`<next><location><measures>`).
        case hairpin(bars: Int, visible: Bool = true)
        /// A rest under a trill to the next barline — a spanner the post-pass draws.
        case trill
        /// A rest under a volta, a system spanner.
        case volta
        /// A whole note tied into the next bar, and the note that bar opens with.
        case tieStart, tieEnd
    }

    private static let wholeNote = Note(pitch: 60, tpc: 14)

    private static func elements(_ bar: Bar) -> [VoiceElement] {
        let rest = VoiceElement.rest(duration: .measure)
        switch bar {
        case .rest: return [rest]
        case .note: return [.chord(Chord(duration: .whole, notes: [wholeNote]))]
        case .dynamic: return [.dynamic(Dynamic(subtype: "f", velocity: 96)), rest]
        case .hiddenDynamic: return [.dynamic(Dynamic(subtype: "f", velocity: 96, visible: false)), rest]
        case .harmony: return [.harmony(Harmony(name: "m7", rootTpc: 14)), rest]
        case .fermataRest: return [.fermata(Fermata(subtype: "fermataAbove")), rest]
        case .measureRepeat: return [.measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure))]
        case .slurredNote:
            let slur = Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 2)
            return [.chord(Chord(duration: .whole, notes: [wholeNote], spanners: [slur]))]
        case let .hairpin(bars, visible):
            // A hidden begin side, not an end marker (which `visible: false` alone would make it).
            let hairpin = Spanner(
                kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: bars, visible: visible,
                hairpin: .init(subtype: .crescendo), isEndMarker: false,
            )
            return [.spanner(hairpin), rest]
        case .trill:
            return [.spanner(Spanner(kind: .trill, rawType: "Trill", nextMeasuresOffset: 1)), rest]
        case .volta:
            return [.spanner(Spanner(kind: .volta, rawType: "Volta", nextMeasuresOffset: 1, voltaEndings: [1])), rest]
        case .tieStart:
            return [.chord(Chord(duration: .whole, notes: [Note(pitch: 48, tpc: 14, tieForward: 1)]))]
        case .tieEnd:
            return [.chord(Chord(duration: .whole, notes: [Note(pitch: 48, tpc: 14, tieBack: 1)]))]
        }
    }

    /// A staff of `bars`. `breaks` ends a system after every bar (read off the score's first staff).
    static func staff(
        _ bars: [Bar], breaks: Bool = false, hide: AutoOnOff = .auto, showIfEmpty: Bool = false,
        sectionBreakAfter: Int? = nil,
    ) -> Staff {
        var staff = Staff(measures: bars.enumerated().map { index, bar in
            var measure = Measure(
                voices: [Voice(elements: elements(bar))], lineBreak: breaks,
                sectionBreak: index == sectionBreakAfter,
            )
            if case .measureRepeat = bar { measure.measureRepeatCount = 1 }
            return measure
        })
        staff.hideWhenEmpty = hide
        staff.showIfSystemEmpty = showIfEmpty
        return staff
    }

    static func part(
        _ name: String, _ staves: [Staff], hide: AutoOnOff = .auto, individually: Bool = false,
        brackets: [BracketItem] = [],
    ) -> Part {
        var staves = staves
        staves[0].brackets = brackets
        var part = Part(
            id: name, instrument: Instrument(id: name, longName: name, shortName: String(name.prefix(2)) + "."),
            staves: IdentifiedArray(staves),
        )
        part.hideWhenEmpty = hide
        part.hideStavesWhenIndividuallyEmpty = individually
        return part
    }

    static func score(
        _ parts: [Part], hideEmptyStaves: Bool = true, dontHideFirst: Bool = true,
        lane: [[PositionedSystemElement]] = [], style: (inout ScoreStyle) -> Void = { _ in },
    ) -> Score {
        var score = Score(
            division: 480, parts: IdentifiedArray(parts),
            systemMeasures: IdentifiedArray(lane.map { SystemMeasure(elements: $0) }),
        )
        score.style.hideEmptyStaves = hideEmptyStaves
        score.style.dontHideStavesInFirstSystem = dontHideFirst
        style(&score.style)
        return score
    }

    static func shown(_ score: Score, _ range: Range<Int>, first: Bool = false) -> [Bool] {
        LayoutEngine.shownStaves(score: score, measureRange: range, isFirstSystem: first)
    }

    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let oboe = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 2, staffIndexInPart: 0)

    // MARK: - The decision

    @Test("with the style off and every setting auto, nothing hides")
    func styleOffHidesNothing() {
        let score = Self.score(
            [Self.part("Fl", [Self.staff([.note])]), Self.part("Vc", [Self.staff([.rest])])],
            hideEmptyStaves: false,
        )
        #expect(Self.shown(score, 0 ..< 1) == [true, true])
    }

    @Test("the style hides an empty part outside the first system, and in it only without dontHideStavesInFirstSystem")
    func styleAndFirstSystem() {
        let parts = [Self.part("Fl", [Self.staff([.note])]), Self.part("Vc", [Self.staff([.rest])])]
        #expect(Self.shown(Self.score(parts), 0 ..< 1) == [true, false])
        #expect(Self.shown(Self.score(parts), 0 ..< 1, first: true) == [true, true])
        #expect(Self.shown(Self.score(parts, dontHideFirst: false), 0 ..< 1, first: true) == [true, false])
    }

    @Test("a staff's own setting wins over its part's, and a part's over the style")
    func precedence() {
        let note = Self.part("Fl", [Self.staff([.note])])
        // Part off: shown although the style hides.
        #expect(Self.shown(Self.score([note, Self.part("Vc", [Self.staff([.rest])], hide: .off)]), 0 ..< 1)
            == [true, true])
        // Staff on: hidden although the style is off — even in a first system.
        let staffOn = Self.score([note, Self.part("Vc", [Self.staff([.rest], hide: .on)])], hideEmptyStaves: false)
        #expect(Self.shown(staffOn, 0 ..< 1, first: true) == [true, false])
        // Staff off: shown although its part is on.
        #expect(Self.shown(Self.score([note, Self.part("Vc", [Self.staff([.rest], hide: .off)], hide: .on)]), 0 ..< 1)
            == [true, true])
        // Part on: hidden although the style is off.
        let partOn = Self.score([note, Self.part("Vc", [Self.staff([.rest])], hide: .on)], hideEmptyStaves: false)
        #expect(Self.shown(partOn, 0 ..< 1) == [true, false])
    }

    @Test("a two-staff part hides a staff on its own only when it hides them individually")
    func individuallyOrTogether() {
        let flute = Self.part("Fl", [Self.staff([.note])])
        let pianoStaves = [Self.staff([.note]), Self.staff([.rest])]
        let together = Self.score([flute, Self.part("Pno", pianoStaves)])
        #expect(Self.shown(together, 0 ..< 1) == [true, true, true])
        let individually = Self.score([flute, Self.part("Pno", pianoStaves, individually: true)])
        #expect(Self.shown(individually, 0 ..< 1) == [true, true, false])
        let bothEmpty = Self.score([flute, Self.part("Pno", [Self.staff([.rest]), Self.staff([.rest])])])
        #expect(Self.shown(bothEmpty, 0 ..< 1) == [true, false, false])
    }

    @Test("a staff spanner reaching into the system keeps the staff, hidden or not; one ending at its start does not")
    func spannersKeepTheStaff() {
        let flute = Self.part("Fl", [Self.staff([.note, .note, .note])])
        func cello(_ bars: [Bar]) -> Score {
            Self.score([flute, Self.part("Vc", [Self.staff(bars)])])
        }
        // A hairpin from bar 0 over three barlines covers bar 1.
        #expect(Self.shown(cello([.hairpin(bars: 3), .rest, .rest]), 1 ..< 2) == [true, true])
        #expect(Self.shown(cello([.hairpin(bars: 3, visible: false), .rest, .rest]), 1 ..< 2) == [true, true])
        // One reaching one barline on ends where bar 1 starts.
        #expect(Self.shown(cello([.hairpin(bars: 1), .rest, .rest]), 1 ..< 2) == [true, false])
        // A slur from bar 0 to bar 2 holds the rest between.
        #expect(Self.shown(cello([.slurredNote, .rest, .note]), 1 ..< 2) == [true, true])
        // A volta is a system spanner: it keeps no staff.
        #expect(Self.shown(cello([.volta, .rest, .rest]), 0 ..< 1) == [true, false])
    }

    @Test("a visible staff annotation keeps the staff; a hidden one, a fermata and a system object do not")
    func annotations() {
        let flute = Self.part("Fl", [Self.staff([.note])])
        func cello(_ bar: Bar, lane: [PositionedSystemElement] = []) -> Score {
            Self.score([flute, Self.part("Vc", [Self.staff([bar])])], lane: [lane])
        }
        #expect(Self.shown(cello(.dynamic), 0 ..< 1) == [true, true])
        #expect(Self.shown(cello(.harmony), 0 ..< 1) == [true, true])
        #expect(Self.shown(cello(.hiddenDynamic), 0 ..< 1) == [true, false])
        #expect(Self.shown(cello(.fermataRest), 0 ..< 1) == [true, false])
        let staffText = PositionedSystemElement(
            position: .start, element: .staffText(StaffText(text: "pizz.")), originalStaff: Self.oboe,
        )
        #expect(Self.shown(cello(.rest, lane: [staffText]), 0 ..< 1) == [true, true])
        let systemText = PositionedSystemElement(
            position: .start, element: .staffText(StaffText(text: "Tutti", isSystemText: true)),
            originalStaff: Self.oboe,
        )
        #expect(Self.shown(cello(.rest, lane: [systemText]), 0 ..< 1) == [true, false])
        let tempo = PositionedSystemElement(
            position: .start, element: .tempo(Tempo(beatsPerSecond: 2)), originalStaff: Self.oboe,
        )
        #expect(Self.shown(cello(.rest, lane: [tempo]), 0 ..< 1) == [true, false])
    }

    @Test("a measure repeat keeps the staff")
    func measureRepeat() {
        let score = Self.score([
            Self.part("Fl", [Self.staff([.note])]), Self.part("Vc", [Self.staff([.measureRepeat])]),
        ])
        #expect(Self.shown(score, 0 ..< 1) == [true, true])
    }

    @Test("a system left empty gets back its showIfSystemEmpty staves, or else its first staff")
    func emptySystem() {
        let showIfEmpty = Self.score([
            Self.part("Fl", [Self.staff([.rest])]), Self.part("Vc", [Self.staff([.rest], showIfEmpty: true)]),
        ])
        #expect(Self.shown(showIfEmpty, 0 ..< 1) == [false, true])
        let plain = Self.score([Self.part("Fl", [Self.staff([.rest])]), Self.part("Vc", [Self.staff([.rest])])])
        #expect(Self.shown(plain, 0 ..< 1) == [true, false])
    }

    @Test("a single-staff score never hides its staff")
    func singleStaff() {
        let score = Self.score([Self.part("Fl", [Self.staff([.rest], hide: .on)])])
        #expect(Self.shown(score, 0 ..< 1) == [true])
    }

    // MARK: - Layout

    /// Flute, oboe and cello, one bar to a system; the oboe rests in the second.
    private static func trio(
        oboe: [Bar] = [.note, .rest, .note], flute: [Bar] = [.note, .note, .note], brackets: [BracketItem] = [],
        lane: [[PositionedSystemElement]] = [], style: (inout ScoreStyle) -> Void = { _ in },
    ) -> Score {
        score([
            part("Flute", [staff(flute, breaks: true)], brackets: brackets),
            part("Oboe", [staff(oboe)]),
            part("Cello", [staff([.note, .note, .note])]),
        ], lane: lane, style: style)
    }

    private static func layout(_ score: Score, hides: Bool = true) -> LayoutDocument {
        var options = ScoreViewOptions(staffSize: 20, wrapToViewWidth: true, includeTitleFrame: false)
        options.hidesEmptyStaves = hides
        return LayoutEngine.layout(score: score, options: options, availableWidth: 600)
    }

    private static func count(_ system: LayoutSystem, where matches: (LayoutElement) -> Bool) -> Int {
        system.measures.reduce(0) { $0 + $1.elements.count(where: matches) }
    }

    @Test("a system leaves out the staff empty in it, and the staves keep their score-wide addresses")
    func compactsTheHiddenStaff() throws {
        let doc = Self.layout(Self.trio())
        try #require(doc.systems.count == 3)
        #expect(doc.systems[0].staffAddresses == [Self.flute, Self.oboe, Self.cello])
        #expect(doc.systems[1].staffAddresses == [Self.flute, Self.cello])
        #expect(doc.systems[2].staffAddresses == [Self.flute, Self.oboe, Self.cello])
        for system in doc.systems {
            #expect(system.staffOrigins.count == system.staffAddresses.count)
            #expect(system.staffGeometries.count == system.staffAddresses.count)
        }
        let middle = doc.systems[1]
        #expect(middle.flatIndex(for: Self.oboe) == nil)
        #expect(middle.flatIndex(for: Self.cello) == 1)
        // Nothing of the oboe is drawn: no rest, one clef and one barline per shown staff.
        #expect(Self.count(middle) { if case .rest = $0 { true } else { false } } == 0)
        #expect(Self.count(middle) { if case .clef = $0 { true } else { false } } == 2)
        #expect(Self.count(middle) { if case .barLine = $0 { true } else { false } } == 2)
        #expect(middle.partLabels.compactMap(\.elementID) == [
            .partName(partIndex: 0, form: .short), .partName(partIndex: 2, form: .short),
        ])
        // The cello moves up into the oboe's room.
        #expect(middle.size.height < doc.systems[2].size.height - doc.metrics.sp * 4)
    }

    @Test("with the option off every system draws every staff")
    func optionOff() {
        let doc = Self.layout(Self.trio(), hides: false)
        #expect(doc.systems.map(\.staffAddresses) == Array(repeating: [Self.flute, Self.oboe, Self.cello], count: 3))
    }

    @Test("brackets are trimmed to the shown staves, and dropped at one staff unless the style keeps them")
    func brackets() throws {
        let brackets = [
            BracketItem(type: .normal, span: 3, column: 0),
            BracketItem(type: .square, span: 2, column: 1),
        ]
        let middle = try #require(Self.layout(Self.trio(brackets: brackets)).systems.dropFirst().first)
        // The three-staff bracket still spans flute to cello over the hidden oboe; the brace count is the shown two.
        #expect(middle.brackets.map(\.type) == [.normal])
        #expect(middle.brackets.first?.staffCount == 2)
        #expect(middle.brackets.first?.topY == middle.staffOrigins[0].y)
        // The flute-and-oboe square bracket is left one staff: drawn only under its style.
        let kept = try #require(Self.layout(Self.trio(brackets: brackets) {
            $0.alwaysShowSquareBracketsWhenHidingStaves = true
        }).systems.dropFirst().first)
        #expect(kept.brackets.map(\.type) == [.normal, .square])
        #expect(kept.brackets.last?.staffCount == 1)
    }

    @Test("with the top staff hidden its system objects and the measure number move to the first shown staff")
    func systemObjectsMoveDown() throws {
        let tempo = PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2)))
        let score = Self.trio(oboe: [.note, .note, .note], flute: [.note, .rest, .note], lane: [[], [tempo], []])
        let middle = try #require(Self.layout(score).systems.dropFirst().first)
        #expect(middle.staffAddresses == [Self.oboe, Self.cello])
        let tempoMarks = Self.count(middle) {
            if case let .textMark(kind, _, _, _) = $0, case .tempo = kind { true } else { false }
        }
        #expect(tempoMarks == 1)
        #expect(Self.count(middle) { if case .measureNumber = $0 { true } else { false } } == 1)
    }

    @Test("a tie across a system break pairs although a staff above it is hidden in the next system")
    func tieAcrossTheBreak() {
        let score = Self.score([
            Self.part("Flute", [Self.staff([.note, .note], breaks: true)]),
            Self.part("Oboe", [Self.staff([.note, .rest])]),
            Self.part("Cello", [Self.staff([.tieStart, .tieEnd])]),
        ])
        func ties(_ doc: LayoutDocument) -> Int {
            doc.systems.reduce(0) { total, system in
                total + system.spanners.count { if case .tieArc = $0 { true } else { false } }
            }
        }
        let hidden = Self.layout(score)
        #expect(hidden.systems.last?.staffAddresses == [Self.flute, Self.cello])
        #expect(ties(hidden) == ties(Self.layout(score, hides: false)))
        #expect(ties(hidden) > 0)
    }

    @Test("a post-pass spanner is drawn on its own staff's row when a staff above it is hidden")
    func spannerRowFollowsTheAddress() throws {
        let score = Self.score([
            Self.part("Flute", [Self.staff([.note, .note], breaks: true)]),
            Self.part("Oboe", [Self.staff([.note, .rest])]),
            Self.part("Cello", [Self.staff([.note, .trill])]),
            Self.part("Bass", [Self.staff([.note, .note])]),
        ])
        let last = try #require(Self.layout(score).systems.last)
        let celloAddress = StaffAddress(partIndex: 2, staffIndexInPart: 0)
        #expect(last.staffAddresses.count == 3)
        let row = try #require(last.flatIndex(for: celloAddress))
        let trillY = last.spanners.compactMap { element -> CGFloat? in
            guard case let .spannerSegment(kind, from, _, _, _, _, _, _, _) = element, case .trill = kind else {
                return nil
            }
            return from.y
        }
        #expect(trillY == [last.staffOrigins[row].y - last.sp * 4])
    }

    @Test("a sticky header over a system that hides a staff gives each row its own staff's clef")
    func stickyHeaderPairsByAddress() throws {
        var cello = Self.staff([.note, .note])
        cello.defaultClefType = "F"
        let score = Self.score([
            Self.part("Flute", [Self.staff([.note, .note], breaks: true)]),
            Self.part("Oboe", [Self.staff([.note, .rest])]),
            Self.part("Cello", [cello]),
        ])
        let template = try #require(Self.layout(score).systems.last)
        #expect(template.staffAddresses == [Self.flute, Self.cello])
        let context = try #require(LayoutEngine.measureContexts(for: score).last)
        let header = LayoutEngine.stickyHeaderSystem(for: context, templateSystem: template, metrics: StaffMetrics(
            staffSize: 20, spacing: .standard,
        ))
        let clefs = header.measures.flatMap(\.elements).compactMap { element -> String? in
            if case let .clef(rawType, _, _, _) = element { rawType } else { nil }
        }
        #expect(clefs == ["G", "F"])
    }

    @Test("the system after a section break is a first system")
    func sectionBreakOpensAFirstSystem() throws {
        let score = Self.score([
            Self.part("Flute", [Self.staff([.note, .note, .note], breaks: true, sectionBreakAfter: 0)]),
            Self.part("Oboe", [Self.staff([.rest, .rest, .rest])]),
        ])
        let doc = Self.layout(score)
        try #require(doc.systems.count == 3)
        #expect(doc.systems.map(\.staffAddresses.count) == [2, 2, 1])
    }
}
