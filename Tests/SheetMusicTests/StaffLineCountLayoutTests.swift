#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("Staff line count — layout")
    struct StaffLineCountLayoutTests {
        private let _installApple = TestSupport.installApple

        private func twoStaffScore(topLineCount: Int) -> Score {
            let c4 = Note(pitch: 60, tpc: 14)
            let c3 = Note(pitch: 48, tpc: 14)
            let top = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [c4])),
            ])])
            let bottom = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "F")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [c3])),
            ])])
            let part = Part(
                id: "P1",
                trackName: "Piano",
                instrument: Instrument(
                    id: "pno", longName: "Piano", shortName: "Pno.",
                ),
                staves: [
                    Staff(lineCount: topLineCount, measures: [top]),
                    Staff(measures: [bottom]),
                ],
            )
            return Score(division: 480, parts: [part])
        }

        @Test("A one-line top staff pulls the staff below it up by 4 sp")
        func aOneLineStaffTakesLessVerticalRoom() throws {
            guard #available(macOS 15.0, *) else { return }

            func gap(topLineCount: Int) throws -> (dy: CGFloat, sp: CGFloat) {
                let doc = LayoutEngine.layout(
                    score: twoStaffScore(topLineCount: topLineCount),
                    options: .init(wrapToViewWidth: false),
                    availableWidth: 900,
                )
                let system = try #require(doc.systems.first)
                #expect(system.staffOrigins.count == 2)
                return (
                    system.staffOrigins[1].y - system.staffOrigins[0].y,
                    system.sp,
                )
            }

            let five = try gap(topLineCount: 5)
            let one = try gap(topLineCount: 1)
            // A one-line staff is 0 sp tall vs the five-line staff's
            // 4 sp, so the staff below moves up — but NOT by a clean
            // 4 sp. `staffBottomLocal` is the band the adaptive
            // staff-distance padding is measured against; once it is
            // per-staff, the C4 notehead hangs below a zero-height
            // one-line band and inflates that pad. Assert the direction
            // and the ceiling, not an exact delta. (Measured here:
            // 4 sp less staff plus 3 sp more pad, so the staff below
            // rises by 1 sp, not 4.)
            #expect(one.dy < five.dy)
            #expect(five.dy - one.dy <= five.sp * 4 + 0.001)
        }

        @Test("Geometry reaches the laid-out system")
        func systemCarriesPerStaffGeometry() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = LayoutEngine.layout(
                score: twoStaffScore(topLineCount: 3),
                options: .init(wrapToViewWidth: false),
                availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            #expect(system.geometry(atFlatIndex: 0).lineCount == 3)
            #expect(system.geometry(atFlatIndex: 1).lineCount == 5)
        }
    }
#endif
