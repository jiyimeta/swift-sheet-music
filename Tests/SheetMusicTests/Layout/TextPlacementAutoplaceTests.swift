import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

@Suite("Text placement autoplace and hits")
struct TextPlacementAutoplaceTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private let metrics = TextPlacementFixtures.metrics

    @Test(arguments: [Placement.above, .below])
    func resolvedSideSurvivesOffsetAcrossStaff(side: Placement) throws {
        let startY: CGFloat = side == .above ? 100 : -40
        let mark = LayoutElement.staffText(
            text: "Ag",
            origin: CGPoint(x: 80, y: startY),
            color: nil,
            style: .staffText,
            anchor: nil,
            placement: TextPlacementMetadata(side: side),
        )
        var measures = [[mark]]
        SkylineAutoplacePass.run(
            measures: &measures,
            xOffsets: [0],
            systemRightX: 200,
            staffTop: 14,
            staffBottom: 42,
            metrics: metrics,
        )
        let rect = try #require(TextInkGeometry.rects(for: measures[0][0], metrics: metrics)?.first)
        if side == .above { #expect(rect.maxY <= 10.5) } else { #expect(rect.minY >= 45.5) }
        #expect(measures[0][0].textPlacement?.side == side)
    }

    @Test func disabledAutoplaceIsFixedAndStillAnObstacle() throws {
        let fixed = LayoutElement.staffText(
            text: "Ag",
            origin: CGPoint(x: 80, y: 75),
            color: nil,
            style: .staffText,
            anchor: nil,
            placement: TextPlacementMetadata(side: .below, autoplace: false),
        )
        let moving = LayoutElement.rehearsalMark(
            text: "B",
            origin: CGPoint(x: 80, y: 75),
            frame: .rectangle,
            color: nil,
            measureIndex: 0,
            placement: TextPlacementMetadata(side: .below),
        )
        var measures = [[fixed, moving]]
        SkylineAutoplacePass.run(
            measures: &measures,
            xOffsets: [0],
            systemRightX: 200,
            staffTop: 14,
            staffBottom: 42,
            metrics: metrics,
        )
        #expect(measures[0][0] == fixed)
        let fixedBox = try #require(TextInkGeometry.rects(for: fixed, metrics: metrics)?.first)
        let movingBox = try #require(TextInkGeometry.rects(for: measures[0][1], metrics: metrics)?
            .reduce(CGRect.null) { $0.union($1) })
        #expect(movingBox.minY - fixedBox.maxY >= metrics.sp * 0.5 - 0.001)
    }

    @Test func belowTextClearsPedalDynamicsAndLyricInk() throws {
        let elements: [LayoutElement] = [
            .textMark(kind: .dynamic(anchor: nil), text: "ff", origin: CGPoint(x: 80, y: 52)),
            .spannerSegment(
                kind: .pedal,
                fromOrigin: CGPoint(x: 65, y: 55),
                toOrigin: CGPoint(x: 150, y: 55),
                continuesLeft: false,
                continuesRight: false,
                text: "",
                anchor: nil,
            ),
            .textMark(
                kind: .lyrics(verse: 0, placement: TextPlacementMetadata(side: .below, verse: 0)),
                text: "Ag",
                origin: CGPoint(x: 80, y: 60),
            ),
            .staffText(
                text: "below",
                origin: CGPoint(x: 80, y: 65),
                color: nil,
                style: .staffText,
                anchor: nil,
                placement: TextPlacementMetadata(side: .below),
            ),
        ]
        var measures = [elements]
        SkylineAutoplacePass.run(
            measures: &measures,
            xOffsets: [0],
            systemRightX: 200,
            staffTop: 14,
            staffBottom: 42,
            metrics: metrics,
        )
        let textBox = try #require(TextInkGeometry.rects(for: measures[0][3], metrics: metrics)?.first)
        let lyricBox = try #require(TextInkGeometry.rects(for: measures[0][2], metrics: metrics)?.first)
        #expect(textBox.minY - lyricBox.maxY >= 3.5 - 0.001)
        let pedal = try #require(LayoutElementShape.shape(for: measures[0][1], id: 1, xOffset: 0, metrics: metrics)?
            .bbox)
        #expect(lyricBox.minY - pedal.maxY >= 1.75 - 0.001)
    }

    @Test(arguments: [TextPlacementRole.lyrics, .staffText, .systemText, .rehearsalMark, .harmonyA])
    func newPositionHitsAndPreviousStaffRelativePositionMisses(role: TextPlacementRole) throws {
        guard #available(macOS 15.0, *) else { return }
        let previous = TextPlacementFixtures.layout(TextPlacementFixtures.score(role: role))
        let side: Placement = role == .lyrics ? .above : .below
        let current = TextPlacementFixtures.layout(TextPlacementFixtures.score(role: role, side: side))
        let oldMark = try #require(TextPlacementFixtures.mark(previous))
        let mark = try #require(TextPlacementFixtures.mark(current))
        let target = try ScoreHitTarget(textID: #require(mark.textID))
        let tester = ScoreHitTester(document: current)
        let newBox = try #require(tester.textHitRect(for: target))
        #expect(tester.hitTest(at: CGPoint(x: newBox.midX, y: newBox.midY)) == target)
        let oldTester = ScoreHitTester(document: previous)
        let oldTarget = try ScoreHitTarget(textID: #require(oldMark.textID))
        let oldBox = try #require(oldTester.textHitRect(for: oldTarget))
        let beforeStaff = try #require(previous.systems.first).origin
            .y + (previous.systems.first?.staffOrigins.first?.y ?? 0)
        let afterStaff = try #require(current.systems.first).origin
            .y + (current.systems.first?.staffOrigins.first?.y ?? 0)
        #expect(tester.hitTest(at: CGPoint(x: oldBox.midX, y: oldBox.midY + afterStaff - beforeStaff)) != target)
    }
}
