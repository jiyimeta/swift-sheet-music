#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// MuseScore stores a hairpin's direction in
    /// `<HairPin><subtype>` (0 = crescendo, 1 = decrescendo) while the
    /// `<Spanner type="…">` attribute is the literal string `HairPin`
    /// for BOTH directions. Layout must therefore read the decoded
    /// payload, not the raw type string.
    @Suite("Hairpin direction")
    struct HairpinDirectionLayoutTests {
        private let _installApple = TestSupport.installApple

        private static func score(
            subtype: Spanner.HairpinPayload.Subtype,
        ) -> Score {
            let note = Note(pitch: 60, tpc: 14)
            let hairpin = Spanner(
                kind: .hairpin, rawType: "HairPin",
                nextMeasuresOffset: 1,
                hairpin: .init(subtype: subtype),
            )
            let m1 = Measure(voices: [Voice(elements: [
                .spanner(hairpin),
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            let m2 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [note])),
            ])])
            return Score(division: 480, parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [m1, m2])],
            )])
        }

        private static func hairpinKind(
            subtype: Spanner.HairpinPayload.Subtype,
        ) -> LayoutElement.SpannerKind? {
            let doc = LayoutEngine.layout(
                score: score(subtype: subtype),
                options: .init(),
                availableWidth: 800,
            )
            for system in doc.systems {
                for element in system.spanners {
                    guard case let .spannerSegment(kind, _, _, _, _, _) =
                        element
                    else { continue }
                    if kind == .hairpinOpen || kind == .hairpinClose {
                        return kind
                    }
                }
            }
            return nil
        }

        @Test("subtype 0 lays out as an opening wedge (crescendo)")
        func crescendoOpens() {
            guard #available(macOS 15.0, *) else { return }
            #expect(Self.hairpinKind(subtype: .crescendo) == .hairpinOpen)
        }

        @Test("subtype 1 lays out as a closing wedge (decrescendo)")
        func decrescendoCloses() {
            guard #available(macOS 15.0, *) else { return }
            #expect(Self.hairpinKind(subtype: .decrescendo) == .hairpinClose)
        }

        @Test("collectSpanners carries the hairpin subtype into the anchor")
        func anchorCarriesSubtype() {
            guard #available(macOS 15.0, *) else { return }
            let anchor = LayoutEngine
                .collectSpanners(score: Self.score(subtype: .decrescendo))
                .first
            #expect(anchor?.hairpinSubtype == .decrescendo)
        }
    }
#endif
