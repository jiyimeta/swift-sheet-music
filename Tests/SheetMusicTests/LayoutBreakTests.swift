#if !os(Android)
    import Foundation
    @testable import SheetMusic
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    struct LayoutBreakTests {
        private let _installApple = TestSupport.installApple

        /// `<LayoutBreak><subtype>line</subtype>` on a measure parses
        /// into `Measure.lineBreak == true`.
        @Test func parsesLineBreak() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1">
                  <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
                  <Instrument id="x"><longName>X</longName></Instrument>
                </Part>
                <Staff id="1">
                  <Measure>
                    <voice></voice>
                  </Measure>
                  <Measure>
                    <LayoutBreak>
                      <subtype>line</subtype>
                    </LayoutBreak>
                    <voice></voice>
                  </Measure>
                  <Measure>
                    <voice></voice>
                  </Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
            let measures = score.parts[0].staves[0].measures
            #expect(measures[0].lineBreak == false)
            #expect(measures[1].lineBreak == true)
            #expect(measures[2].lineBreak == false)
        }

        /// `<LayoutBreak><subtype>page</subtype>` is parsed into
        /// `Measure.pageBreak`. It does NOT set `lineBreak` —
        /// honoring "page break implies line break" happens at layout
        /// time (`measureForcesLineBreak`), not parse time.
        @Test func parsesPageBreak() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1">
                  <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
                  <Instrument id="x"><longName>X</longName></Instrument>
                </Part>
                <Staff id="1">
                  <Measure>
                    <LayoutBreak>
                      <subtype>page</subtype>
                    </LayoutBreak>
                    <voice></voice>
                  </Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
            #expect(score.parts[0].staves[0].measures[0].pageBreak == true)
            #expect(score.parts[0].staves[0].measures[0].lineBreak == false)
        }

        /// `LayoutEngine.measureForcesLineBreak(at:staves:)` consults
        /// only staff 0 (line breaks are document-level), and treats
        /// page-break as also forcing a system break (mirrors
        /// `engraving/rendering/score/systemlayout.cpp:262`).
        @Test func helperReadsStaffZero() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let mLine = Measure(voices: [], lineBreak: true)
            let mPage = Measure(voices: [], pageBreak: true)
            let mPlain = Measure(voices: [])
            let staves = [
                Staff(measures: [mLine, mPage, mPlain]),
                Staff(measures: [mPlain, mPlain, mPlain]),
            ]
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 0, staves: staves, policy: .honor,
            ) == true)
            #expect(
                LayoutEngine.measureForcesLineBreak(
                    at: 1, staves: staves, policy: .honor,
                ) == true,
                "page break should also force a system break",
            )
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 2, staves: staves, policy: .honor,
            ) == false)
            // Out-of-range index returns false rather than crashing.
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 99, staves: staves, policy: .honor,
            ) == false)
        }

        /// `measureForcesLineBreak` honours `LayoutBreakPolicy`:
        /// `.honor` keeps the existing line-or-page logic;
        /// `.ignoreSystemBreaks` only respects page breaks;
        /// `.ignoreAll` returns false unconditionally.
        @Test func helperHonoursPolicy() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let mLine = Measure(voices: [], lineBreak: true)
            let mPage = Measure(voices: [], pageBreak: true)
            let mPlain = Measure(voices: [])
            let staves = [Staff(measures: [mLine, mPage, mPlain])]

            // .honor — line and page both force.
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 0, staves: staves, policy: .honor,
            ) == true)
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 1, staves: staves, policy: .honor,
            ) == true)
            // .ignoreSystemBreaks — line ignored, page still forces.
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 0, staves: staves, policy: .ignoreSystemBreaks,
            ) == false)
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 1, staves: staves, policy: .ignoreSystemBreaks,
            ) == true)
            // .ignoreAll — neither forces.
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 0, staves: staves, policy: .ignoreAll,
            ) == false)
            #expect(LayoutEngine.measureForcesLineBreak(
                at: 1, staves: staves, policy: .ignoreAll,
            ) == false)
            // Plain measure: false under every policy.
            for p: LayoutBreakPolicy in [.honor, .ignoreSystemBreaks, .ignoreAll] {
                #expect(LayoutEngine.measureForcesLineBreak(
                    at: 2, staves: staves, policy: p,
                ) == false)
            }
        }

        /// `.ignoreAll` collapses authored line breaks: the same fixture
        /// that produces three systems under `.honor` produces a single
        /// system when the policy ignores breaks. Mirrors spec test case 1.
        @Test func ignoreAllCollapsesAuthoredLineBreaks() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            // Six measures with a forced line break on indices 1 and 3 —
            // identical fixture to `layoutBreakForcesSystemSplit`.
            let measures = (0 ..< 6).map { idx in
                Measure(
                    voices: [Voice(elements: [
                        .chord(chord), .chord(chord),
                        .chord(chord), .chord(chord),
                    ])],
                    lineBreak: idx == 1 || idx == 3,
                )
            }
            let staff = Staff(measures: measures)
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            let opts = ScoreViewOptions(
                staffSize: 16, systemGap: 16,
                wrapToViewWidth: true,
                breakPolicy: .ignoreAll,
            )
            // Wide enough that no width-driven wrap fires either.
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: 4000,
            )
            #expect(doc.systems.count == 1)
            #expect(doc.systems.first?.measures.count == 6)
        }

        /// `.ignoreSystemBreaks` keeps `<LayoutBreak>page`-implied system
        /// breaks. Mirrors spec test case 2.
        @Test func ignoreSystemBreaksKeepsPageImpliedSystemBreaks() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            // Six measures, page break on measure 2 (index 2).
            let measures = (0 ..< 6).map { idx in
                Measure(
                    voices: [Voice(elements: [
                        .chord(chord), .chord(chord),
                        .chord(chord), .chord(chord),
                    ])],
                    pageBreak: idx == 2,
                )
            }
            let staff = Staff(measures: measures)
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            let opts = ScoreViewOptions(
                staffSize: 16, systemGap: 16,
                wrapToViewWidth: true,
                breakPolicy: .ignoreSystemBreaks,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: 4000,
            )
            // Page break on measure 2 → still forces a system break,
            // even under .ignoreSystemBreaks. Two systems: 3 + 3.
            #expect(doc.systems.count == 2)
            #expect(doc.systems[0].measures.count == 3)
            #expect(doc.systems[1].measures.count == 3)
        }

        /// Between two forced breaks (or between start-of-score and the
        /// first break), measures should split evenly across systems
        /// rather than greedily packing the first system. Mirrors
        /// MuseScore's "balanced wrap" preference: when an 8-measure
        /// span needs 2 systems to fit, prefer 4+4 over 6+2 or 7+1.
        @Test func balancedWrapBetweenBreaks() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // Construct measures wide enough that 8 of them force a
            // 2-system split, but with each measure narrow enough that
            // a greedy packer could pack 6 in the first system. We use
            // a quarter-note chord per measure so the duration-driven
            // width is meaningful.
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            let baseMeasure = Measure(voices: [Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord), .chord(chord),
                .chord(chord), .chord(chord),
            ])])
            let measures = (0 ..< 8).map { idx -> Measure in
                var m = baseMeasure
                if idx == 7 { m.lineBreak = true }
                return m
            }
            let staff = Staff(measures: measures)
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            // Width chosen so greedy packing would land 5+3 but
            // balanced wrap collapses that to 4+4. Each measure's
            // `crossStaffMinimumMeasureWidth` is ~48.65 pt at
            // staffSize=14 (contentStartX 5.5 sp + 4 quarters at
            // 1.6 sp/quarter + trailingGap 1 sp + leading sp).
            // Part labels here floor to sp*4 = 14 pt (first system)
            // / sp*2 = 7 pt (after) since `nil → ""` track names.
            // With contentAvail = 386 first / 393 after:
            //   * greedy + 1.5x natural stretch fits 5 in system 1
            //     (5×48.65 + 7 = 250.25 ≤ 386/1.5 ≈ 257);
            //   * balanced wrap rejects chunk=8 (8×48.65 + 7 =
            //     396.2 > 386) and returns chunk=4 (201.6 ≤ 386),
            //     so the system packer caps at 4 — collapsing
            //     greedy 5+3 to 4+4.
            let opts = ScoreViewOptions(
                staffSize: 14, systemGap: 16, wrapToViewWidth: true,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: 400,
            )
            // Two systems, 4 measures each — not 5+3 / 6+2 / 7+1.
            #expect(doc.systems.count == 2)
            #expect(doc.systems[0].measures.count == 4)
            #expect(doc.systems[1].measures.count == 4)
        }

        /// Horizontal mode (`wrapToViewWidth = false`) must ignore
        /// line breaks — the whole score lays out as a single
        /// continuous strip. Mirrors MuseScore's
        /// `LayoutMode::HORIZONTAL_FIXED` branch in
        /// `engraving/rendering/score/systemlayout.cpp:265-269`.
        @Test func horizontalModeIgnoresLineBreaks() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            // Six measures with a forced line break on every odd index.
            let measures = (0 ..< 6).map { idx in
                Measure(
                    voices: [Voice(elements: [
                        .chord(chord), .chord(chord),
                        .chord(chord), .chord(chord),
                    ])],
                    lineBreak: idx % 2 == 1,
                )
            }
            let staff = Staff(measures: measures)
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 16, systemGap: 16,
                    wrapToViewWidth: false,
                ),
                availableWidth: 4000,
            )
            // wrapToViewWidth=false → one system holds every measure
            // regardless of LayoutBreaks.
            #expect(doc.systems.count == 1)
            #expect(doc.systems.first?.measures.count == 6)
        }

        /// A score with explicit line breaks every 2 measures produces
        /// one system per pair regardless of how many would otherwise
        /// fit horizontally.
        @Test func layoutBreakForcesSystemSplit() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            // Six measures, with `lineBreak` on indices 1 and 3 (so
            // breaks land *after* measures 2 and 4).
            let measures = (0 ..< 6).map { idx in
                Measure(
                    voices: [Voice(elements: [
                        .chord(chord), .chord(chord),
                        .chord(chord), .chord(chord),
                    ])],
                    lineBreak: idx == 1 || idx == 3,
                )
            }
            let staff = Staff(measures: measures)
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 16, systemGap: 16,
                    wrapToViewWidth: true,
                ),
                availableWidth: 4000,
            ) // wide enough that nothing
            // wraps from horizontal overflow
            // Two explicit breaks → three systems.
            #expect(doc.systems.count == 3)
        }

        /// `PagedScoreView.paginate` honours `<LayoutBreak>page` under
        /// `.honor` (closing the page early) and ignores it under
        /// `.ignoreAll` (only vertical overflow closes pages).
        /// Mirrors spec test case 3.
        @Test func paginateHonoursPolicy() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            /// Three lightweight systems, each 100 pt tall. Page height
            /// 1000 pt easily fits them all on one page — only a
            /// pageBreak flag should split them.
            func makeSystem(pageBreak: Bool) -> LayoutSystem {
                let m = LayoutMeasure(
                    measureIndex: 0,
                    origin: .zero,
                    width: 100,
                    elements: [],
                    pageBreak: pageBreak,
                )
                return LayoutSystem(
                    origin: .zero,
                    size: CGSize(width: 100, height: 100),
                    measures: [m],
                    staffOrigins: [],
                    partLabels: [],
                    spanners: [],
                    sp: 7,
                )
            }
            let systems = [
                makeSystem(pageBreak: false),
                makeSystem(pageBreak: true), // forces page close
                makeSystem(pageBreak: false),
            ]

            let honor = PagedScoreView.paginate(
                systems: systems, pageHeight: 1000, policy: .honor,
            )
            #expect(
                honor.count == 2,
                "page break on system 1 should close page after it",
            )
            #expect(honor[0].count == 2)
            #expect(honor[1].count == 1)

            let ignoreSysBreaks = PagedScoreView.paginate(
                systems: systems, pageHeight: 1000,
                policy: .ignoreSystemBreaks,
            )
            #expect(
                ignoreSysBreaks.count == 2,
                ".ignoreSystemBreaks still closes pages on pageBreak",
            )

            let ignoreAll = PagedScoreView.paginate(
                systems: systems, pageHeight: 1000, policy: .ignoreAll,
            )
            #expect(
                ignoreAll.count == 1,
                ".ignoreAll lets all systems share one page",
            )
            #expect(ignoreAll[0].count == 3)
        }

        /// `LayoutBreakPolicy` is `Sendable & Equatable`, has the three
        /// designed cases, and `ScoreViewOptions` defaults `breakPolicy`
        /// to `.honor` for source-compatibility.
        @Test func breakPolicyDefault() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let opts = ScoreViewOptions()
            #expect(opts.breakPolicy == .honor)
            let custom = ScoreViewOptions(breakPolicy: .ignoreAll)
            #expect(custom.breakPolicy == .ignoreAll)
            // All three cases distinct.
            let cases: [LayoutBreakPolicy] = [
                .honor, .ignoreSystemBreaks, .ignoreAll,
            ]
            #expect(Set(cases.map { "\($0)" }).count == 3)
        }
    }
#endif
