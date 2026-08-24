#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The two silent-failure points on the path that lets a spanner
    /// segment take part in `SkylineAutoplacePass`.
    ///
    /// Both used to be no-ops with no error and no visible effect:
    /// `translate` returned the element unchanged, so any `dy` the pass
    /// computed was discarded, and `elementYPoints` reported only the
    /// anchor line, so a segment's ink never reserved system height.
    @Suite("Spanner segment plumbing")
    struct SpannerSegmentPlumbingTests {
        private static func segment(
            kind: LayoutElement.SpannerKind = .ottava(
                subtype: .eightVB, numbersOnly: true,
            ),
            y: CGFloat = 40,
        ) -> LayoutElement {
            .spannerSegment(
                kind: kind,
                fromOrigin: CGPoint(x: 10, y: y),
                toOrigin: CGPoint(x: 90, y: y),
                continuesLeft: false,
                continuesRight: true,
                text: "8",
            )
        }

        @Test("translate shifts both endpoints and keeps the payload")
        func translateShiftsSpannerSegment() {
            let moved = LayoutEngine.translate(
                element: Self.segment(y: 40), dy: 7,
            )
            guard case let .spannerSegment(
                kind, from, to, continuesLeft, continuesRight, text,
            ) = moved else {
                Issue.record("expected a spannerSegment, got \(moved)")
                return
            }
            #expect(from.y == 47)
            #expect(to.y == 47)
            // X is untouched — `translate` is vertical only.
            #expect(from.x == 10)
            #expect(to.x == 90)
            #expect(continuesLeft == false)
            #expect(continuesRight == true)
            #expect(text == "8")
            if case .ottava = kind {} else {
                Issue.record("kind was rewritten: \(kind)")
            }
        }

        @Test("elementYPoints reports the segment's full ink band")
        func yPointsCoverTheInkBand() {
            let sp: CGFloat = 8
            let ys = LayoutEngine.elementYPoints(
                Self.segment(y: 40), sp: sp,
            )
            // `ottavaLabelSizeSp` = 2.5 sp ⇒ ±1.25 sp about the anchor.
            let half = sp * SpannerGeometry.ottavaLabelSizeSp / 2
            #expect(ys.min() == 40 - half)
            #expect(ys.max() == 40 + half)
            // 1.25 sp exceeds the flat 1 sp `glyphPad` in
            // `elementYBounds`, which is the whole reason `sp` is
            // threaded in.
            #expect(half > sp)
        }

        @Test("elementYPoints without sp reports only the anchor line")
        func yPointsWithoutSpAreAnchorOnly() {
            let ys = LayoutEngine.elementYPoints(Self.segment(y: 40))
            #expect(ys == [40, 40])
        }

        @Test("the reserved band matches the shape the skyline sees")
        func yPointsAgreeWithTheShape() throws {
            let metrics = StaffMetrics(staffSize: 28)
            for kind: LayoutElement.SpannerKind in [
                .hairpinOpen, .hairpinClose, .pedal,
                .ottava(subtype: .eightVB, numbersOnly: true),
                .palmMute, .letRing, .volta(endings: [1]),
            ] {
                let element = Self.segment(kind: kind, y: 40)
                let ys = LayoutEngine.elementYPoints(
                    element, sp: metrics.sp,
                )
                let shape = try #require(LayoutElementShape.shape(
                    for: element, id: 0, xOffset: 0, metrics: metrics,
                ))
                let box = try #require(shape.bbox)
                #expect(abs((ys.min() ?? 0) - box.minY) < 0.001)
                #expect(abs((ys.max() ?? 0) - box.maxY) < 0.001)
            }
        }
    }
#endif
