#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A note at `step`, positioned so the chord's middle-line Y is 0.
    /// `origin.y = -step * sp / 2` inverts the pass's own
    /// `staffMidY = origin.y + step * sp / 2`.
    private func note(step: Int, sp: CGFloat, mirror: Bool = false) -> LayoutChordNote {
        LayoutChordNote(
            noteID: NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
                noteIndexInChord: 0,
            ),
            step: step,
            accidental: nil,
            origin: CGPoint(x: 100, y: -CGFloat(step) * sp / 2),
            tieForward: nil,
            tieBack: nil,
            hasGlissando: false,
            headType: nil,
            mirror: mirror,
            isInvisible: false,
            color: nil,
            accidentalBracket: .none,
            parentheses: .none,
        )
    }

    struct LedgerLinePassTests {
        let metrics = StaffMetrics(staffSize: 28)

        @Test func noStrokesInsideTheStaff() {
            let strokes = LedgerLinePass.strokes(
                for: [note(step: 4, sp: metrics.sp), note(step: -4, sp: metrics.sp)],
                stem: .up, metrics: metrics,
                firstStepAbove: 6, firstStepBelow: -6,
            )
            #expect(strokes.isEmpty)
        }

        @Test func oneStrokeForMiddleC() {
            // step -6 is the first ledger position below a five-line staff.
            let strokes = LedgerLinePass.strokes(
                for: [note(step: -6, sp: metrics.sp)],
                stem: .up, metrics: metrics,
                firstStepAbove: 6, firstStepBelow: -6,
            )
            #expect(strokes.count == 1)
            guard case let .ledgerLine(from, to, thickness) = strokes[0] else {
                Issue.record("expected .ledgerLine, got \(strokes[0])")
                return
            }
            #expect(from.y == metrics.sp * 3) // -(-6) * sp / 2
            #expect(to.y == from.y)
            #expect(from.x == 100 - metrics.sp * 0.9)
            #expect(to.x == 100 + metrics.sp * 0.9)
            #expect(thickness == metrics.staffLineThickness * 1.5)
        }

        @Test func oddStepSnapsToTheLineBelowIt() {
            // step -7 sits in the space below the -6 ledger; only the
            // -6 stroke is drawn.
            let strokes = LedgerLinePass.strokes(
                for: [note(step: -7, sp: metrics.sp)],
                stem: .up, metrics: metrics,
                firstStepAbove: 6, firstStepBelow: -6,
            )
            #expect(strokes.count == 1)
        }

        @Test func multipleStrokesStrideByTwo() {
            let strokes = LedgerLinePass.strokes(
                for: [note(step: 10, sp: metrics.sp)],
                stem: .up, metrics: metrics,
                firstStepAbove: 6, firstStepBelow: -6,
            )
            // steps 6, 8, 10
            #expect(strokes.count == 3)
        }

        @Test func aThreeLineStaffStartsItsLowerLedgersHigher() {
            // A three-line staff's bottom line is step 0, so the first
            // ledger below sits at step -2.
            let strokes = LedgerLinePass.strokes(
                for: [note(step: -4, sp: metrics.sp)],
                stem: .up, metrics: metrics,
                firstStepAbove: 6, firstStepBelow: -2,
            )
            // steps -2, -4
            #expect(strokes.count == 2)
        }

        @Test func graceChordsGetLedgerLinesToo() {
            let grace = LayoutElement.graceChord(
                notes: [note(step: -6, sp: metrics.sp)],
                duration: .eighth,
                stem: .up,
                stemOrigin: .zero,
                relativeX: -10,
                hasSlash: true,
                mag: 1.0,
                voiceIndex: 0,
            )
            let out = LedgerLinePass.insert(
                into: [grace], metrics: metrics,
                firstStepAbove: 6, firstStepBelow: -6,
                invisibleNotes: false,
            )
            #expect(out.count == 2)
            guard case .ledgerLine = out[0] else {
                Issue.record("ledger must precede its grace chord")
                return
            }
        }
    }
#endif
