#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// A 2- or 4-bar measure repeat as MuseScore engraves it: the sign in the group's anchor bar, drawn on that bar's
/// trailing barline — the group's middle — with the bar count above it; a click selects it only on its ink; a group
/// bar the sign does not stand in still draws a selection; and the group never splits across systems.
@Suite("Measure repeat group layout")
struct MeasureRepeatGroupLayoutTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// `bars` 4/4 bars of eight eighth notes on one staff, bar 0 opening with the meter, and a measure-repeat group of
    /// each `(firstBar, numMeasures)`.
    private static func score(bars: Int = 8, groups: [(Int, Int)]) throws -> Score {
        let eighths: [VoiceElement] = (0 ..< 8).map { index in
            .chord(Chord(duration: .eighth, notes: [Note(pitch: 60 + index, tpc: 14)]))
        }
        let meter = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let measures = (0 ..< bars).map { index in
            Measure(voices: [Voice(elements: (index == 0 ? [meter] : []) + eighths)])
        }
        var score = Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "drums"), staves: [Staff(measures: measures)]),
        ])
        for (first, count) in groups {
            _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: first), staff: staff, numMeasures: count)
                .apply(to: &score)
        }
        return score
    }

    private static func layout(_ score: Score, width: CGFloat = 4000) -> LayoutDocument {
        _ = TestSupport.installFontMetrics
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: width)
    }

    /// A sign as drawn, with the system and measure it is drawn in.
    private struct DrawnSign {
        let system: LayoutSystem
        let measure: LayoutMeasure
        let count: Int
        let origin: CGPoint
        let restID: RestID
    }

    /// The one sign `document` draws.
    private static func sign(in document: LayoutDocument) throws -> DrawnSign {
        for system in document.systems {
            for measure in system.measures {
                for case let .measureRepeat(count, origin, restID?) in measure.elements {
                    return DrawnSign(system: system, measure: measure, count: count, origin: origin, restID: restID)
                }
            }
        }
        throw MissingSign()
    }

    private struct MissingSign: Error {}

    private static func trailingBarLineX(of measure: LayoutMeasure) -> CGFloat? {
        measure.elements.compactMap { element -> CGFloat? in
            guard case let .barLine(_, origin, _, _, role) = element, role == .trailing else { return nil }
            return origin.x
        }.max()
    }

    private static func signBar(_ score: Score) -> [Int] {
        score.parts[0].staves[0].measures.indices.filter { index in
            score.parts[0].staves[0].measures[index].voices[0].elements.values.contains {
                if case .measureRepeat = $0 { true } else { false }
            }
        }
    }

    // MARK: - Where the sign stands

    @Test("a 2-bar group's sign stands in its first bar, a 4-bar group's in its second")
    func signAnchorsAsMuseScoreDoes() throws {
        #expect(try Self.signBar(Self.score(groups: [(1, 1)])) == [1])
        #expect(try Self.signBar(Self.score(groups: [(1, 2)])) == [1])
        #expect(try Self.signBar(Self.score(groups: [(1, 4)])) == [2])
    }

    @Test("a 2- or 4-bar sign is drawn with its own glyph on its bar's trailing barline, the group's middle")
    func evenSignSitsOnTheMiddleBarline() throws {
        for (count, signBar) in [(2, 1), (4, 2)] {
            let sign = try Self.sign(in: Self.layout(Self.score(groups: [(1, count)])))
            #expect(sign.count == count)
            #expect(sign.measure.measureIndex == signBar)
            #expect(sign.origin.x == Self.trailingBarLineX(of: sign.measure))
        }
    }

    @Test("a 1-bar sign is drawn in the middle of its bar")
    func oneBarSignIsCentered() throws {
        let sign = try Self.sign(in: Self.layout(Self.score(groups: [(1, 1)])))
        #expect(sign.count == 1)
        #expect(sign.origin.x == sign.measure.width / 2)
    }

    @Test("a 2- or 4-bar sign carries its count above the staff, a 1-bar sign none")
    func numberStandsAboveTheStaff() throws {
        let sp: CGFloat = 10
        #expect(MeasureRepeatGlyph.numberRect(forCount: 1, sp: sp) == nil)
        for count in [2, 4] {
            let number = try #require(MeasureRepeatGlyph.numberRect(forCount: count, sp: sp))
            // The sign is centered on the middle line, so the top line is 2 sp above it: the digit clears it by about
            // half a space, MuseScore's `measureRepeatNumberPos`.
            #expect(abs(number.maxY - -2.5 * sp) < 0.05 * sp)
            #expect(MeasureRepeatGlyph.numberCodepoint(forCount: count) == SMuFLCodepoint.timeSigDigit(count))
        }
    }

    // MARK: - Clicking it

    @Test("a click on the sign's ink selects it; above or below it, it does not")
    func signIsHitByItsInk() throws {
        guard #available(macOS 15.0, *) else { return }
        for count in [1, 2] {
            let document = try Self.layout(Self.score(groups: [(1, count)]))
            let sign = try Self.sign(in: document)
            let sp = document.metrics.sp
            let center = CGPoint(
                x: sign.system.origin.x + sign.measure.origin.x + sign.origin.x,
                y: sign.system.origin.y + sign.measure.origin.y + sign.origin.y,
            )
            let tester = ScoreHitTester(document: document)
            #expect(tester.hitTest(at: center) == .rest(sign.restID))
            // Below the glyph (1.06 sp half-height, plus the half-space reach): still on the staff, not the sign.
            #expect(tester.hitTest(at: CGPoint(x: center.x, y: center.y + sp * 1.8)) != .rest(sign.restID))
            if count == 2 {
                let number = try #require(MeasureRepeatGlyph.numberCenter(forCount: count, sp: sp))
                let onNumber = CGPoint(x: center.x + number.x, y: center.y + number.y)
                #expect(tester.hitTest(at: onNumber) == .rest(sign.restID))
            } else {
                #expect(tester.hitTest(at: CGPoint(x: center.x, y: center.y - sp * 1.8)) != .rest(sign.restID))
            }
        }
    }

    // MARK: - Selecting a group bar the sign does not stand in

    @Test("a range on the rest of a group bar without the sign draws a box across that bar")
    func signlessGroupBarDrawsItsRange() throws {
        let score = try Self.score(groups: [(1, 2)])
        let document = Self.layout(score)
        let rest = RestID(staff: Self.staff, measureIndex: 2, voiceIndex: 0, elementIndex: 0)
        let system = try #require(document.systems.first { $0.measures.contains { $0.measureIndex == 2 } })
        let bar = try #require(system.measures.first { $0.measureIndex == 2 })
        #expect(bar.measureRepeatRests == [rest])
        let box = try #require(system.rangeBoxRect(selectedIDs: [.rest(rest)], metrics: document.metrics))
        let barline = try #require(Self.trailingBarLineX(of: bar))
        #expect(box.minX >= bar.origin.x - document.metrics.sp * 1.4)
        #expect(box.maxX >= bar.origin.x + barline - document.metrics.sp * 1.4)
        #expect(box.maxX <= bar.origin.x + bar.width)
    }

    @Test("a bar outside every group lists no rests under a sign")
    func ordinaryBarListsNone() throws {
        let document = try Self.layout(Self.score(groups: [(1, 2)]))
        let bar = try #require(document.systems.flatMap(\.measures).first { $0.measureIndex == 4 })
        #expect(bar.measureRepeatRests.isEmpty)
    }

    // MARK: - Line breaking

    /// MuseScore marks a group's bars `noBreak` and takes measures back off a line that would end inside one. Across a
    /// sweep of widths, no system may end on a group bar that the group continues past — unless the group opened that
    /// system, and is wider than a line can hold.
    @Test("a group is never split across systems unless it is wider than a line")
    func groupStaysOnOneSystem() throws {
        let score = try Self.score(bars: 14, groups: [(2, 2), (5, 2), (8, 4)])
        let positions = score.parts[0].staves[0].measures.map(\.measureRepeatCount)
        var systemCounts: Set<Int> = []
        var groupsMovedWhole = 0
        for width in stride(from: CGFloat(300), through: 1500, by: 40) {
            let document = Self.layout(score, width: width)
            systemCounts.insert(document.systems.count)
            for system in document.systems.dropLast() {
                let first = try #require(system.measures.first?.measureIndex)
                let last = try #require(system.measures.last?.measureIndex)
                guard positions.indices.contains(last + 1), let next = positions[last + 1], next > 1 else {
                    // The line ends at a group's edge or outside every group; count the lines a group now opens.
                    if positions.indices.contains(last + 1), positions[last + 1] == 1 { groupsMovedWhole += 1 }
                    continue
                }
                let groupStart = last + 1 - (next - 1)
                #expect(groupStart <= first, "width \(width): a system ends at bar \(last), inside a group")
            }
        }
        // The sweep has to reach several line counts and break before a group, or it proved nothing about breaking.
        #expect(systemCounts.count >= 3)
        #expect(groupsMovedWhole > 0)
    }
}
