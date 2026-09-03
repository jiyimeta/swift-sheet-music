#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    // The package does not bundle Edwin — a host registers it via
    // `SheetMusicFonts.register(urls:)` — and `CTFontCreateWithName` answers
    // an unregistered family with a silent system-font fallback rather than
    // nil, so an assertion about *Edwin's own* metrics on a bare CI runner
    // would be an assertion about Helvetica. `TestSupport.installApple`
    // registers the repo's own copy, which is why the suites below can measure
    // Edwin and not the system font.

    /// `HorizontalClampPass` — annotation text is pulled back inside the
    /// system instead of running off the page and being clipped by the
    /// host view.
    ///
    /// Reproduces the shape of `君とParadiso.mscz`: a two-line
    /// `<StaffText>` anchored on the last eighth of a measure that sits
    /// at the end of a system.
    @Suite("Annotation text horizontal clamp")
    struct AnnotationTextClampTests {
        private let _installApple = TestSupport.installApple
        private let staffSize: CGFloat = 28 // sp = 7
        private let availableWidth: CGFloat = 800

        // MARK: - Fixtures

        /// One 4/4 measure of four quarter chords, so tick columns exist
        /// at 0/4 … 3/4 for an annotation to anchor to.
        private func fourQuarterMeasure(withHeader: Bool) -> Measure {
            var elements: [VoiceElement] = []
            if withHeader {
                elements.append(.clef(Clef(concertClefType: "G")))
                elements.append(.timeSignature(
                    TimeSignature(numerator: 4, denominator: 4),
                ))
            }
            for _ in 0 ..< 4 {
                elements.append(.chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 71, tpc: 17)]),
                )))
            }
            return Measure(voices: [Voice(elements: elements)])
        }

        /// Two-measure score with `text` attached at `position` of the
        /// LAST measure.
        private func score(
            text: String,
            position: MeasurePosition,
            offsetX: Double = 0,
            inFirstMeasure: Bool = false,
        ) -> Score {
            let annotated = SystemMeasure(elements: [
                PositionedSystemElement(
                    position: position,
                    element: .staffText(StaffText(
                        text: text, offsetX: offsetX,
                    )),
                ),
            ])
            let empty = SystemMeasure()
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [
                        fourQuarterMeasure(withHeader: true),
                        fourQuarterMeasure(withHeader: false),
                    ])],
                )],
                systemMeasures: inFirstMeasure
                    ? [annotated, empty]
                    : [empty, annotated],
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        private func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: staffSize),
                availableWidth: availableWidth,
            )
        }

        /// Document-space ink box of the first `.staffText` in `doc`,
        /// paired with the horizontal bounds of its own system.
        @available(macOS 15.0, iOS 16.0, *)
        private func staffTextBox(
            in doc: LayoutDocument,
        ) -> (box: CGRect, systemLeftX: CGFloat, systemRightX: CGFloat)? {
            let metrics = StaffMetrics(staffSize: staffSize)
            for system in doc.systems {
                guard let first = system.measures.first,
                      let last = system.measures.last else { continue }
                for measure in system.measures {
                    for el in measure.elements {
                        guard case .staffText = el,
                              let shape = LayoutElementShape.shape(
                                  for: el, id: 0,
                                  xOffset: measure.origin.x,
                                  metrics: metrics,
                              ),
                              let box = shape.bbox
                        else { continue }
                        return (
                            box,
                            first.origin.x,
                            last.origin.x + last.width,
                        )
                    }
                }
            }
            return nil
        }

        // MARK: - Clamp

        /// The reported case: a wide two-line annotation on the last
        /// beat of the last measure. Without the clamp its box runs
        /// past the final barline and off the page.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func wideTextAtSystemEndIsPulledInside() throws {
            let doc = layout(score(
                text: "アタック強め\nクレッシェンドなし",
                position: MeasurePosition(numerator: 3, denominator: 4),
            ))
            let placed = try #require(staffTextBox(in: doc))
            #expect(
                placed.box.maxX <= placed.systemRightX + 0.01,
                "text \(placed.box.maxX) vs system \(placed.systemRightX)",
            )
            // Sanity: the fixture must actually be wide enough to
            // overflow, or the assertion above passes vacuously.
            #expect(placed.box.width > 40)
        }

        /// The clamp measures each line separately.
        ///
        /// Two controls, both clamped against the same system edge: the
        /// widest LINE of the fixture, and the fixture's two lines
        /// CONCATENATED. Measuring the raw `\n` string through one
        /// `CTLine` — the bug — would make the two-line text land with
        /// the concatenation; measuring per line lands it with the
        /// widest line.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func multiLineTextIsMeasuredPerLine() throws {
            let position = MeasurePosition(numerator: 3, denominator: 4)
            let twoLine = try #require(staffTextBox(in: layout(score(
                text: "アタック強め\nクレッシェンドなし",
                position: position,
            ))))
            let widestLine = try #require(staffTextBox(in: layout(score(
                text: "クレッシェンドなし", position: position,
            ))))
            let concatenated = try #require(staffTextBox(in: layout(score(
                text: "アタック強めクレッシェンドなし", position: position,
            ))))
            #expect(abs(twoLine.box.minX - widestLine.box.minX) < 0.01)
            #expect(abs(twoLine.box.minX - concatenated.box.minX) > 1)
        }

        /// An annotation that already fits is left exactly where
        /// `LayoutEngine+Placement` put it — at its tick column, with no
        /// gratuitous shift.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func textThatFitsIsNotMoved() throws {
            let doc = layout(score(
                text: "a", position: .start,
            ))
            let system = try #require(doc.systems.first)
            var found = false
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .staffText(_, origin, _, _) = el
                    else { continue }
                    let column = try #require(measure.tickColumns[0])
                    #expect(abs(origin.x - column) < 0.01)
                    found = true
                }
            }
            #expect(found, "no staff text was laid out")
        }

        /// A large negative `<offset>` would put the text in the
        /// instrument-name gutter; it is clamped to the system's left
        /// edge and no further.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func textOverflowingTheLeftEdgeIsPulledInside() throws {
            let doc = layout(score(
                text: "cresc.", position: .start,
                offsetX: -20, inFirstMeasure: true,
            ))
            let placed = try #require(staffTextBox(in: doc))
            #expect(
                placed.box.minX >= placed.systemLeftX - 0.01,
                "text \(placed.box.minX) vs system \(placed.systemLeftX)",
            )
            #expect(placed.box.minX <= placed.systemLeftX + 0.01)
        }
    }

    /// `LayoutElementShape.textRect` measuring multi-line payloads.
    @Suite("Multi-line text rects")
    struct MultiLineTextRectTests {
        private let _installApple = TestSupport.installApple
        private let font = LayoutFont(face: "Edwin", pointSize: 12)

        /// Width is the WIDEST line, not the concatenation of all lines
        /// — the bug that made the clamp overshoot.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func widthIsTheWidestLine() {
            let provider = FontMetrics.provider
            let wide = provider.typographicWidth(
                text: "BBBBBBBB", font: font,
            )
            let rect = LayoutElementShape.textRect(
                text: "AAA\nBBBBBBBB", font: font,
                origin: .zero, anchor: .bottomLeading,
            )
            #expect(abs(rect.width - wide) < 0.01)
        }

        /// Height covers the whole stack, and with `.bottomLeading` the
        /// second line hangs BELOW the origin — matching how
        /// `ScoreLayerBuilder+Helpers.textPath` draws it.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func heightCoversEveryLineAndHangsBelowTheOrigin() {
            let provider = FontMetrics.provider
            let ascent = provider.ascent(font: font)
            let descent = provider.descent(font: font)
            let leading = provider.leading(font: font)
            let lineHeight = ascent + descent + leading
            let rect = LayoutElementShape.textRect(
                text: "AAA\nBBB", font: font,
                origin: CGPoint(x: 10, y: 100), anchor: .bottomLeading,
            )
            #expect(
                abs(rect.height - (ascent + descent + lineHeight)) < 0.01,
            )
            #expect(abs(rect.minY - (100 - ascent - descent)) < 0.01)
            #expect(abs(rect.maxY - (100 + lineHeight)) < 0.01)
        }

        /// Edwin asks for a 0.2 em line gap, so a provider that ignored
        /// `leading` would stack the lines too tightly. This used to be
        /// skipped where Edwin isn't installed — a bare CI runner, and most
        /// dev machines — because CoreText answers an unregistered family with
        /// the system font, whose leading is 0, and the assertion would have
        /// been about Helvetica. `TestSupport.installApple` now registers the
        /// repo's Edwin, so it runs everywhere and means what it says.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func appleProviderReportsEdwinsLeading() {
            #expect(FontMetrics.provider.leading(font: font) > 0)
        }

        /// Regression pin: single-line rects keep the pre-multi-line
        /// geometry exactly.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func singleLineRectIsUnchanged() {
            let provider = FontMetrics.provider
            let width = provider.typographicWidth(text: "mf", font: font)
            let height = provider.ascent(font: font)
                + provider.descent(font: font)
            let origin = CGPoint(x: 10, y: 100)
            for anchor: TextAnchorConvention in [
                .bottomLeading, .leadingCenter, .center,
            ] {
                let rect = LayoutElementShape.textRect(
                    text: "mf", font: font,
                    origin: origin, anchor: anchor,
                )
                #expect(abs(rect.width - width) < 0.01)
                #expect(abs(rect.height - height) < 0.01)
                switch anchor {
                case .bottomLeading:
                    #expect(abs(rect.minY - (100 - height)) < 0.01)
                    #expect(abs(rect.minX - 10) < 0.01)
                case .leadingCenter:
                    #expect(abs(rect.minY - (100 - height / 2)) < 0.01)
                    #expect(abs(rect.minX - 10) < 0.01)
                case .center:
                    #expect(abs(rect.minY - (100 - height / 2)) < 0.01)
                    #expect(abs(rect.minX - (10 - width / 2)) < 0.01)
                }
            }
        }
    }
#endif
