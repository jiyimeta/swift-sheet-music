#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Chords drawn on a sibling staff (`Chord.staffMove`, MuseScore's `<staffMove>`): placed in the target staff's frame
/// with its clef, handed to that staff's buffer, stemmed toward their own staff, and — when a beam group straddles the
/// two staves — beamed between them once both staves are placed.
@Suite("Cross-staff layout")
struct CrossStaffLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private typealias Fixture = CrossStaffFixture

    private static let treble = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func layout(_ data: Data) throws -> LayoutDocument {
        try layout(Fixture.parse(data))
    }

    private static func layout(_ score: Score, width: CGFloat = 1200, cache: LayoutCache? = nil) -> LayoutDocument {
        let options = ScoreViewOptions(staffSize: 20, wrapToViewWidth: true, includeTitleFrame: false)
        return LayoutEngine.layout(score: score, options: options, availableWidth: width, cache: cache)
    }

    private struct DrawnChord {
        let elementIndex: Int
        let writtenOn: StaffAddress
        let noteYs: [CGFloat]
        let stem: StemDirection
        let stemOrigin: CGPoint
        let isBeamed: Bool
    }

    /// The chords of measure `measure`, in system coordinates.
    private static func chords(_ doc: LayoutDocument, measure: Int) throws -> [DrawnChord] {
        let system = try #require(doc.systems.first)
        let laidOut = try #require(system.measures.first { $0.measureIndex == measure })
        return laidOut.elements.compactMap { element in
            guard case let .chord(notes, _, stem, stemOrigin, _, _, isBeamed, _, _, _, _) = element,
                  let id = notes.first?.noteID
            else { return nil }
            return DrawnChord(
                elementIndex: id.elementIndex, writtenOn: id.staff,
                noteYs: notes.map { laidOut.origin.y + $0.origin.y }, stem: stem,
                stemOrigin: CGPoint(x: laidOut.origin.x + stemOrigin.x, y: laidOut.origin.y + stemOrigin.y),
                isBeamed: isBeamed,
            )
        }.sorted { $0.stemOrigin.x < $1.stemOrigin.x }
    }

    private static func elements(_ doc: LayoutDocument, measure: Int) throws -> [LayoutElement] {
        try #require(doc.systems.first?.measures.first { $0.measureIndex == measure }).elements
    }

    private static func ledgerCount(_ doc: LayoutDocument, measure: Int) throws -> Int {
        try elements(doc, measure: measure).count { if case .ledgerLine = $0 { true } else { false } }
    }

    private static func row(_ doc: LayoutDocument, _ index: Int) throws -> CGFloat {
        try #require(doc.systems.first).staffOrigins[index].y
    }

    private static let descending = [(55, 15), (53, 13), (52, 18), (50, 16)] // G3 F3 E3 D3
    private static let ascending = [(60, 14), (62, 16), (64, 18), (65, 13)] // C4 D4 E4 F4

    // MARK: - A whole chord on the other staff

    @Test("a chord moved down is drawn where the same chord written on the bass staff is, with its stem up")
    func movedDownLandsOnTheBassStaff() throws {
        let moved = try Self.layout(Fixture.piano(
            treble: [Self.descending.map { Fixture.chord([$0], move: 1) }.joined()],
            bass: [Fixture.rest("measure")],
        ))
        let native = try Self.layout(Fixture.piano(
            treble: [Fixture.rest("measure")],
            bass: [Self.descending.map { Fixture.chord([$0]) }.joined()],
        ))
        let movedChords = try Self.chords(moved, measure: 0)
        let nativeChords = try Self.chords(native, measure: 0)
        try #require(movedChords.count == 4 && nativeChords.count == 4)
        let movedRow = try Self.row(moved, 1)
        let nativeRow = try Self.row(native, 1)
        for (drawn, reference) in zip(movedChords, nativeChords) {
            #expect(drawn.writtenOn == Self.treble)
            #expect(drawn.noteYs.map { $0 - movedRow } == reference.noteYs.map { $0 - nativeRow })
            #expect(drawn.stem == .up)
        }
        // G3–D3 sit inside the bass staff: drawn in the treble's frame they would hang three ledger lines.
        #expect(try Self.ledgerCount(moved, measure: 0) == 0)
    }

    @Test("a chord moved up is drawn on the treble staff, with its stem down and the treble's ledger lines")
    func movedUpLandsOnTheTrebleStaff() throws {
        let moved = try Self.layout(Fixture.piano(
            treble: [Fixture.rest("measure")],
            bass: [Self.ascending.map { Fixture.chord([$0], move: -1) }.joined()],
        ))
        let native = try Self.layout(Fixture.piano(
            treble: [Self.ascending.map { Fixture.chord([$0]) }.joined()],
            bass: [Fixture.rest("measure")],
        ))
        let movedChords = try Self.chords(moved, measure: 0)
        let nativeChords = try Self.chords(native, measure: 0)
        try #require(movedChords.count == 4 && nativeChords.count == 4)
        let movedRow = try Self.row(moved, 0)
        let nativeRow = try Self.row(native, 0)
        for (drawn, reference) in zip(movedChords, nativeChords) {
            #expect(drawn.noteYs.map { $0 - movedRow } == reference.noteYs.map { $0 - nativeRow })
            #expect(drawn.stem == .down)
        }
        #expect(try Self.ledgerCount(moved, measure: 0) == Self.ledgerCount(native, measure: 0))
        #expect(try Self.ledgerCount(moved, measure: 0) > 0)
    }

    @Test("a beam group moved as a whole stems toward its own staff, as MuseScore draws it")
    func wholeGroupMoveSetsTheBeamSide() throws {
        let doc = try Self.layout(Fixture.piano(
            treble: [Self.descending.map { Fixture.chord([$0], "eighth", move: 1) }.joined() + Fixture.rest("half")],
            bass: [Fixture.rest("half") + Self.ascending.map { Fixture.chord([$0], "eighth", move: -1) }.joined()],
        ))
        let chords = try Self.chords(doc, measure: 0)
        try #require(chords.count == 8)
        #expect(chords.filter { $0.writtenOn == Self.treble }.allSatisfy { $0.stem == .up && $0.isBeamed })
        #expect(chords.filter { $0.writtenOn != Self.treble }.allSatisfy { $0.stem == .down && $0.isBeamed })
    }

    // MARK: - A beam across the staves

    /// Measure 1 of MuseScore's own example: an arpeggio climbing from the bass staff into the treble and back.
    private static let arpeggio = Fixture.piano(
        treble: [[
            Fixture.chord([(48, 14)], "eighth", move: 1), Fixture.chord([(55, 15)], "eighth", move: 1),
            Fixture.chord([(60, 14)], "eighth"), Fixture.chord([(64, 18)], "eighth"),
            Fixture.chord([(67, 15)], "eighth"), Fixture.chord([(64, 18)], "eighth"),
            Fixture.chord([(60, 14)], "eighth"), Fixture.chord([(55, 15)], "eighth", move: 1),
        ].joined()],
        bass: [Fixture.rest("measure")],
    )

    @Test("a beam across the staves lies between them, its stems meeting it from both sides")
    func crossStaffBeamMeetsEveryStem() throws {
        let doc = try Self.layout(Self.arpeggio)
        let chords = try Self.chords(doc, measure: 0)
        try #require(chords.count == 8)
        #expect(chords.map(\.stem) == [.up, .up, .down, .down, .down, .down, .down, .up])
        #expect(chords.map(\.isBeamed) == Array(repeating: true, count: 8))
        let laidOut = try #require(doc.systems.first?.measures.first)
        let beams = laidOut.elements.compactMap { element -> (CGPoint, CGPoint)? in
            guard case let .beam(from, to, _, level, _) = element, level == 1 else { return nil }
            return (
                CGPoint(x: from.x + laidOut.origin.x, y: from.y + laidOut.origin.y),
                CGPoint(x: to.x + laidOut.origin.x, y: to.y + laidOut.origin.y),
            )
        }.sorted { $0.0.x < $1.0.x }
        try #require(beams.count == 2)
        let sp = doc.metrics.sp
        for (group, (from, to)) in zip([chords[0 ..< 4], chords[4 ..< 8]], beams) {
            for chord in group {
                let stemX = chord.stemOrigin.x + sp * 0.59 * (chord.stem == .up ? 1 : -1)
                let onBeam = from.y + (to.y - from.y) * (stemX - from.x) / (to.x - from.x)
                #expect(abs(chord.stemOrigin.y - onBeam) < 0.01)
            }
            let lowestAbove = group.filter { $0.stem == .down }.flatMap(\.noteYs).max() ?? 0
            let highestBelow = group.filter { $0.stem == .up }.flatMap(\.noteYs).min() ?? 0
            #expect(lowestAbove < min(from.y, to.y) && max(from.y, to.y) < highestBelow)
        }
        // The first group climbs half a space (MuseScore: the smaller side's first-to-last step, 2 quarter spaces);
        // the second falls.
        #expect(abs((beams[0].0.y - beams[0].1.y) - sp / 2) < 0.01)
        #expect(beams[1].1.y > beams[1].0.y)
    }

    /// A new width rebuilds the system but reuses each staff's placement, which must bring its hand-overs with it.
    @Test("a relayout from cached placements draws the moved chords and the cross-staff beam again")
    func cachedPlacementsKeepTheMoves() throws {
        let score = try Fixture.parse(Self.arpeggio)
        let cache = LayoutCache()
        _ = Self.layout(score, width: 1200, cache: cache)
        let hitsBefore = cache.placementHits
        let warm = Self.layout(score, width: 1100, cache: cache)
        #expect(cache.placementHits > hitsBefore)
        #expect(warm == Self.layout(score, width: 1100))
    }

    // MARK: - The slant

    private static func chord(_ below: Bool, _ line: Int, staff: Int? = nil, rootY: CGFloat = 0) -> CrossBeamChord {
        CrossBeamChord(isBelowBeam: below, staff: staff ?? (below ? 1 : 0), line: line, stemRootY: rootY)
    }

    @Test("the slant follows both sides when they agree, and takes the smaller step")
    func slantFollowsAgreeingSides() {
        // C3 G3 below, C4 E4 above: both sides climb (4 and 2 lines), and so does the switch.
        let climbing = [Self.chord(true, 5), Self.chord(true, 1), Self.chord(false, 10), Self.chord(false, 8)]
        #expect(LayoutEngine.crossStaffBeamSlant(climbing, beamWidth: 9.7, sp: 10) == 2)
        // G4 E4 C4 above, G3 below: the top falls four lines, the single bottom chord is neutral.
        let falling = [Self.chord(false, 6), Self.chord(false, 8), Self.chord(false, 10), Self.chord(true, 1)]
        #expect(LayoutEngine.crossStaffBeamSlant(falling, beamWidth: 9.7, sp: 10) == -4)
        #expect(LayoutEngine.crossStaffBeamSlant(falling, beamWidth: 4, sp: 10) == -2)
    }

    @Test("two chords slant a quarter space per space between their stems' roots")
    func slantOfTwoChords() {
        let pair = [Self.chord(false, 10, rootY: 100), Self.chord(true, 1, rootY: 125)]
        #expect(LayoutEngine.crossStaffBeamSlant(pair, beamWidth: 9.7, sp: 10) == -3)
        #expect(LayoutEngine.crossStaffBeamSlant(pair, beamWidth: 2, sp: 10) == -1)
    }

    @Test("disagreeing sides, or a middle chord reaching past an outer one, keep the beam flat")
    func slantFlattens() {
        let disagreeing = [Self.chord(true, 5), Self.chord(true, 1), Self.chord(false, 10), Self.chord(false, 12)]
        #expect(LayoutEngine.crossStaffBeamSlant(disagreeing, beamWidth: 9.7, sp: 10) == 0)
        let even = [Self.chord(false, 6), Self.chord(false, 7), Self.chord(false, 8), Self.chord(false, 9)]
        #expect(LayoutEngine.crossStaffBeamSlant(even + [Self.chord(true, 1)], beamWidth: 9.7, sp: 10) == -3)
        let reaching = [Self.chord(false, 6), Self.chord(false, 8), Self.chord(false, 12), Self.chord(false, 9)]
        #expect(LayoutEngine.crossStaffBeamSlant(reaching + [Self.chord(true, 1)], beamWidth: 9.7, sp: 10) == 0)
    }

    // MARK: - Ties and hidden staves

    @Test("a tie from a chord into the same voice's moved chord still pairs")
    func tieIntoAMovedChordPairs() throws {
        let tieStart = "<Chord><durationType>half</durationType><Note><Spanner type=\"Tie\"><Tie/><next><location>"
            + "<fractions>1/2</fractions></location></next></Spanner><pitch>55</pitch><tpc>15</tpc></Note></Chord>"
        let tieEnd = "<Chord><staffMove>1</staffMove><durationType>half</durationType><Note><Spanner type=\"Tie\">"
            + "<prev><location><fractions>-1/2</fractions></location></prev></Spanner><pitch>55</pitch><tpc>15</tpc>"
            + "</Note></Chord>"
        let data = Fixture.piano(treble: [tieStart + tieEnd], bass: [Fixture.rest("measure")])
        let notes = try Fixture.chords(Fixture.parse(data), staff: 0).flatMap(\.notes)
        try #require(notes.count == 2 && notes[0].tieForward != nil && notes[1].tieBack != nil)
        let system = try #require(try Self.layout(data).systems.first)
        #expect(system.spanners.count { if case .tieArc = $0 { true } else { false } } == 1)
    }

    @Test("a staff that would hide as empty stays while a sibling's chord is drawn on it")
    func receivingStaffIsNotEmpty() throws {
        func shown(move: Int?) throws -> [Bool] {
            var score = try Fixture.parse(Fixture.piano(
                treble: [Self.descending.map { Fixture.chord([$0], move: move) }.joined()],
                bass: [Fixture.rest("measure")],
            ))
            var parts = Array(score.parts)
            parts[0].hideStavesWhenIndividuallyEmpty = true
            score.parts = IdentifiedArray(parts)
            score.style.hideEmptyStaves = true
            return LayoutEngine.shownStaves(score: score, measureRange: 0 ..< 1, isFirstSystem: false)
        }
        #expect(try shown(move: nil) == [true, false])
        #expect(try shown(move: 1) == [true, true])
    }
}
