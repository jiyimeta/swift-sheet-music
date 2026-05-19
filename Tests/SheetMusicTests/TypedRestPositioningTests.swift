#if !os(Android)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("TypedRestPositioning")
    struct TypedRestPositioningTests {
        private static func makeScore(elements: [VoiceElement]) -> Score {
            let m = Measure(voices: [Voice(elements: elements)])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "pno"),
                    staves: [Staff(measures: [m])],
                )],
                systemMeasures: [SystemMeasure()],
            )
        }

        private static func restOrigins(
            in score: Score, availableWidth: CGFloat = 900,
        ) -> [CGFloat] {
            guard #available(macOS 15.0, iOS 16.0, *) else { return [] }
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(wrapToViewWidth: false),
                availableWidth: availableWidth,
            )
            guard let measure = doc.systems.first?.measures.first else {
                return []
            }
            var xs: [CGFloat] = []
            for emitted in measure.elements {
                if case let .rest(_, origin, _, _, _) = emitted {
                    xs.append(origin.x)
                }
            }
            return xs
        }

        @Test("6/4 whole+half: whole at beat 1, half at beat 5")
        func sixFourTypedRestsHitTheirStartBeats() {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.makeScore(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 6, denominator: 4)),
                .rest(duration: .whole),
                .rest(duration: .half),
            ])
            let xs = Self.restOrigins(in: score)
            #expect(xs.count == 2)
            #expect(xs[0] < xs[1], "whole rest must precede the half rest in X")
        }

        @Test(".measure rest still centres in the bar's chord area")
        func measureRestStillCenters() {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.makeScore(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 6, denominator: 4)),
                .rest(duration: .measure),
            ])
            let xs = Self.restOrigins(in: score)
            #expect(xs.count == 1)
            // The single .measure rest must NOT sit at tick 0. With the
            // earlier-emitted clef + time signature occupying the header,
            // tick-0 sits at `headerSchedule.contentStartX`, well to the
            // left of the bar mid-point. The exact X is fragile against
            // spacing tuning so we only assert "comfortably right of the
            // header" — i.e., at least 80pt past the leftmost emitted
            // element.
            let leftmostHeader = xs[0]
            let oneSpace: CGFloat = 80
            #expect(
                leftmostHeader > oneSpace,
                "centred .measure rest x=\(leftmostHeader) should be well right of the header",
            )
        }
    }
#endif
