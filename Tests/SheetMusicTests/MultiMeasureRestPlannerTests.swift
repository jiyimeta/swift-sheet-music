#if os(macOS) || os(iOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("MultiMeasureRestPlanner")
    struct MultiMeasureRestPlannerTests {
        // MARK: - Helpers

        private static func restMeasure() -> Measure {
            Measure(voices: [Voice(elements: [.rest(duration: .whole)])])
        }

        private static func soundingMeasure() -> Measure {
            let n = Note(pitch: 60, tpc: 14)
            return Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [n])),
            ])])
        }

        private static func score(_ measures: [Measure]) -> Score {
            Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
            )
        }

        // MARK: - Tests

        @Test("disabled returns an empty plan")
        func disabledReturnsEmptyPlan() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(for: s, policy: .disabled)
            #expect(plan.runs.isEmpty)
        }

        @Test("three rest measures collapse with minimum 2")
        func threeRestsCollapseWithMinimumTwo() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 3])
        }

        @Test("two rests do not collapse when minimum is 3")
        func twoRestsBelowMinimumDoNotCollapse() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([Self.restMeasure(), Self.restMeasure()])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 3),
            )
            #expect(plan.runs.isEmpty)
        }

        @Test("minimum below 2 is clamped to 2")
        func minimumBelowTwoIsClampedToTwo() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([Self.restMeasure()])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 1),
            )
            // Single rest cannot collapse even when minimum is 1 (clamped to 2).
            #expect(plan.runs.isEmpty)
        }

        @Test("sounding measure breaks the run")
        func soundingMeasureBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                Self.soundingMeasure(),
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("rehearsal mark in voice breaks run")
        func rehearsalMarkBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let mark = Measure(voices: [Voice(elements: [
                .rehearsalMark(RehearsalMark(text: "A")),
                .rest(duration: .whole),
            ])])
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), mark,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            // The mark-bearing measure is not collapsible; trailing pair collapses.
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("key signature change breaks run")
        func keySignatureChangeBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let keyChange = Measure(voices: [Voice(elements: [
                .keySignature(KeySignature(concertKey: 2)),
                .rest(duration: .whole),
            ])])
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                keyChange,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("time signature change breaks run")
        func timeSignatureChangeBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let tsChange = Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
                .rest(duration: .whole),
            ])])
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                tsChange,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("tempo change breaks run")
        func tempoChangeBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let tempoMeasure = Measure(voices: [Voice(elements: [
                .tempo(Tempo(beatsPerSecond: 2.0)),
                .rest(duration: .whole),
            ])])
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                tempoMeasure,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("startRepeat breaks run before the marked measure")
        func startRepeatBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m = Self.restMeasure()
            m.startRepeat = true
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("endRepeat breaks run inclusive of the marked measure")
        func endRepeatBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m = Self.restMeasure()
            m.endRepeatCount = 2
            let s = Self.score([
                Self.restMeasure(), m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [2 ..< 4])
        }

        @Test("measure-level marker breaks run")
        func markerBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m = Self.restMeasure()
            m.markers = [Marker(kind: .segno, text: "")]
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("voice-level end-repeat barline breaks run")
        func voiceEndRepeatBarLineBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // MSCX may encode an end-repeat via `<BarLine subtype=
            // "end-repeat"/>` rather than `<endRepeat>N</endRepeat>`.
            // In that path `m.endRepeatCount == nil` but the barline
            // is structurally a repeat — collapse must still break.
            let m = Measure(voices: [Voice(elements: [
                .rest(duration: .whole),
                .barLine(BarLine(subtype: "end-repeat")),
            ])])
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("voice-level final barline is preserved in a run")
        func voiceFinalBarLineDoesNotBreakRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // A `<BarLine subtype="end">` (final barline) is a
            // visual-only marker — it should NOT break the run; the
            // collapsed bar's right edge will adopt its subtype.
            let m = Measure(voices: [Voice(elements: [
                .rest(duration: .whole),
                .barLine(BarLine(subtype: "end")),
            ])])
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), m,
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 3])
        }

        @Test("measure-level jump breaks run")
        func jumpBreaksRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m = Self.restMeasure()
            m.jumps = [Jump(jumpTo: "start", playUntil: "end", text: "D.C.")]
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(), m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("authored line break closes the run at that measure")
        func lineBreakClosesRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m1 = Self.restMeasure()
            m1.lineBreak = true
            let s = Self.score([
                m1, Self.restMeasure(), Self.restMeasure(),
                Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            // m0 has lineBreak → run ends after it. m0 is still collapsible
            // by itself, but a run of 1 doesn't meet the minimum.
            // m1..m3 form a collapsible run of 3.
            #expect(plan.runs == [1 ..< 4])
        }

        @Test("page break closes the run at that measure")
        func pageBreakClosesRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m1 = Self.restMeasure()
            m1.pageBreak = true
            let s = Self.score([
                Self.restMeasure(), m1,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            // m0..m1 form a 2-measure run that ends at m1 (pageBreak closes
            // after m1). m2..m3 form a separate 2-measure run.
            #expect(plan.runs == [0 ..< 2, 2 ..< 4])
        }

        @Test("irregular measure is not collapsible")
        func irregularMeasureNotCollapsible() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m = Self.restMeasure()
            m.irregular = true
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("actualLength override is not collapsible")
        func actualLengthOverrideNotCollapsible() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m = Self.restMeasure()
            m.actualLength = Fraction(numerator: 2, denominator: 4)
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("measure-repeat group member is not collapsible")
        func measureRepeatNotCollapsible() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            var m = Self.restMeasure()
            m.measureRepeatCount = 1
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                m,
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 2, 3 ..< 5])
        }

        @Test("open spanner crossing the run blocks collapse")
        func openSpannerBlocksCollapse() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // m0 starts a 4-measure spanner. Even though m1..m3 are rest
            // measures, the spanner is still open across them, so the run
            // is blocked.
            let pedal = Spanner(
                kind: .pedal, rawType: "Pedal",
                nextMeasuresOffset: 4,
            )
            let m0 = Measure(voices: [Voice(elements: [
                .spanner(pedal),
                .rest(duration: .whole),
            ])])
            let s = Self.score([
                m0,
                Self.restMeasure(), Self.restMeasure(),
                Self.restMeasure(),
                Self.restMeasure(), Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            // Pedal runs from m0 across m0..m3 inclusive; closed before m4.
            // m4..m5 collapse normally.
            #expect(plan.runs == [4 ..< 6])
        }

        @Test("multiple staves: collapse only when every staff is silent")
        func multipleStavesAllSilent() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let r = Self.restMeasure()
            let n = Self.soundingMeasure()
            let s = Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [
                        // Staff 0: r, r, r
                        Staff(measures: [r, r, r]),
                        // Staff 1: r, n, r — middle measure has a note
                        Staff(measures: [r, n, r]),
                    ],
                )],
            )
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            // Only m0 and m2 are silent across all staves. They are
            // separated by m1, so neither qualifies as a 2-measure run.
            #expect(plan.runs.isEmpty)
        }

        @Test("location shift alone does not break run")
        func locationShiftIsCollapsible() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let m = Measure(voices: [Voice(elements: [
                .locationShift(delta: Fraction(numerator: 1, denominator: 8)),
                .rest(duration: .whole),
            ])])
            let s = Self.score([
                Self.restMeasure(), m, Self.restMeasure(),
            ])
            let plan = MultiMeasureRestPlanner.plan(
                for: s, policy: .collapse(minimumMeasures: 2),
            )
            #expect(plan.runs == [0 ..< 3])
        }
    }
#endif
