#if !os(Android)
    import CoreGraphics
    @testable import SheetMusicLayout
    import Testing

    struct StaffLineGeometryTests {
        let sp: CGFloat = 7 // StaffMetrics(staffSize: 28).sp

        @Test func standardIsFiveLine() {
            #expect(StaffLineGeometry.standard.lineCount == 5)
        }

        // `topStep` must stay pinned at 4 for every line count: MuseScore
        // anchors note positions to the top line regardless of how many
        // lines are drawn (`Note::updateRelLine` never consults
        // `StaffType::lines()`), so this must never become a function of
        // `lineCount` — that would silently break the plan's central
        // invariant while every other computed value stayed green.
        @Test(arguments: [1, 3, 5, 6, 16])
        func topStepIsAlwaysFour(lineCount: Int) {
            #expect(StaffLineGeometry(lineCount: lineCount).topStep == 4)
        }

        @Test(arguments: [(1, 0), (3, 2), (5, 4), (6, 5), (16, 15)])
        func heightIsOneLessThanTheLineCount(lineCount: Int, spaces: Int) {
            let g = StaffLineGeometry(lineCount: lineCount)
            #expect(g.height(sp: sp) == CGFloat(spaces) * sp)
        }

        @Test(arguments: [(1, 4), (3, 0), (5, -4), (6, -6), (16, -26)])
        func bottomStep(lineCount: Int, expected: Int) {
            #expect(StaffLineGeometry(lineCount: lineCount).bottomStep == expected)
        }

        @Test func ledgerBoundsFollowMuseScore() {
            let five = StaffLineGeometry(lineCount: 5)
            #expect(five.firstLedgerStepAbove == 6)
            #expect(five.firstLedgerStepBelow == -6)
            let three = StaffLineGeometry(lineCount: 3)
            #expect(three.firstLedgerStepAbove == 6)
            #expect(three.firstLedgerStepBelow == -2)
            let sixteen = StaffLineGeometry(lineCount: 16)
            #expect(sixteen.firstLedgerStepAbove == 6)
            #expect(sixteen.firstLedgerStepBelow == -28)
        }

        @Test func lineYStepsDownBySp() {
            let g = StaffLineGeometry(lineCount: 3)
            #expect(g.lineY(0, sp: sp) == 0)
            #expect(g.lineY(2, sp: sp) == sp * 2)
        }

        @Test func barLineSpansTheStaff() {
            let g = StaffLineGeometry(lineCount: 3)
            let span = g.barLineSpanY(sp: sp)
            #expect(span.top == 0)
            #expect(span.bottom == sp * 2)
        }

        @Test func aOneLineStaffGetsMuseScoresSpecialBarLineSpan() {
            // BARLINE_SPAN_1LINESTAFF_FROM/TO = ∓4 half-spaces = ∓2 sp.
            let span = StaffLineGeometry(lineCount: 1).barLineSpanY(sp: sp)
            #expect(span.top == -sp * 2)
            #expect(span.bottom == sp * 2)
        }

        @Test func lineCountIsClamped() {
            #expect(StaffLineGeometry(lineCount: 0).lineCount == 1)
            #expect(StaffLineGeometry(lineCount: 99).lineCount == 16)
        }
    }
#endif
