#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import Testing

    /// The CALayer tree `ScoreView` builds draws a text's authored font override and color. The SwiftUI Canvas
    /// path has its own suite, `TextFontOverrideCanvasTests`.
    ///
    /// Asserted on what was drawn (layer outlines and fills), not on the style resolution that feeds it, so a
    /// renderer that resolved the override and then drew with the default fails here.
    @Suite("Text font overrides reach the CALayer renderer", .serialized)
    struct TextFontOverrideRenderTests {
        private let _installApple = TestSupport.installApple

        private static let red = ScoreColor(red: 200, green: 10, blue: 20)
        private static let large = TextProperties(size: 24)
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        private static func score(lyric: Lyric? = nil, lane: [SystemElement] = []) -> Score {
            let chord = Chord(
                duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), lyrics: lyric.map { [$0] } ?? [],
            )
            return Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: lane.map {
                PositionedSystemElement(position: .start, element: $0, originalStaff: staff)
            })])
        }

        /// The layers the CALayer builder registered for the first element `select` names an item for.
        @available(macOS 15.0, *)
        private static func layers(
            _ score: Score, _ select: (LayoutElement) -> ScoreItemID?,
        ) throws -> [CAShapeLayer] {
            _ = BravuraFont.register
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
            let system = try #require(document.systems.first)
            let item = try #require(system.measures.flatMap(\.elements).lazy.compactMap(select).first)
            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: document.metrics)
            return try #require(built.items[item])
        }

        private static func width(_ layers: [CAShapeLayer]) -> CGFloat {
            layers.compactMap { $0.path?.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }.width
        }

        /// Outline width of the one selectable text in `score`.
        @available(macOS 15.0, *)
        private static func textWidth(_ score: Score) throws -> CGFloat {
            try width(layers(score) { $0.textItemID })
        }

        @available(macOS 15.0, *)
        private static func tempoLayers(_ tempo: Tempo) throws -> [CAShapeLayer] {
            // Only the tempo: a signature or barline in the same bar has an element identity too.
            try layers(score(lane: [.tempo(tempo)])) { element in
                if case .textMark(.tempo, _, _) = element { element.elementItemID } else { nil }
            }
        }

        // MARK: - CALayer

        @available(macOS 15.0, *)
        @Test("the CALayer lyric, staff text and rehearsal mark are drawn at their override size")
        func layerTextsDrawTheOverrideSize() throws {
            let lyric = try Self.textWidth(Self.score(lyric: Lyric(text: "Wonder", properties: Self.large)))
            let plainLyric = try Self.textWidth(Self.score(lyric: Lyric(text: "Wonder")))
            #expect(lyric > plainLyric * 1.5)

            let staffText = try Self.textWidth(Self.score(lane: [
                .staffText(StaffText(text: "dolce", properties: Self.large)),
            ]))
            let plainStaffText = try Self.textWidth(Self.score(lane: [.staffText(StaffText(text: "dolce"))]))
            #expect(staffText > plainStaffText * 1.5)

            let mark = try Self.textWidth(Self.score(lane: [
                .rehearsalMark(RehearsalMark(text: "Chorus", properties: Self.large)),
            ]))
            let plainMark = try Self.textWidth(Self.score(lane: [.rehearsalMark(RehearsalMark(text: "Chorus"))]))
            #expect(mark > plainMark * 1.2)
        }

        /// Face and bold together, through a family CoreText actually has a bold member of — the test host
        /// registers only Edwin's roman, so a bold Edwin would measure and draw exactly like a regular one.
        @available(macOS 15.0, *)
        @Test("the CALayer staff text draws its override face and weight")
        func layerStaffTextDrawsFaceAndWeight() throws {
            func width(_ style: FontStyleSet) throws -> CGFloat {
                let properties = TextProperties(face: "Helvetica", size: 14, style: style)
                return try Self.textWidth(Self.score(lane: [
                    .staffText(StaffText(text: "marcato sempre", properties: properties)),
                ]))
            }
            let bold = try width([.bold])
            let regular = try width([])
            #expect(bold > regular * 1.03)
        }

        @available(macOS 15.0, *)
        @Test("the CALayer tempo marking draws its color and size")
        func layerTempoDrawsColorAndSize() throws {
            var tempo = Tempo(beatsPerSecond: 2, properties: Self.large)
            tempo.elementProperties.color = Self.red
            let styled = try Self.tempoLayers(tempo)
            let plain = try Self.tempoLayers(Tempo(beatsPerSecond: 2))
            #expect(Self.width(styled) > Self.width(plain) * 1.5)
            let fills = styled.compactMap { $0.fillColor?.components }
            #expect(!fills.isEmpty)
            #expect(fills.allSatisfy { abs($0[0] - 200.0 / 255) < 0.01 && abs($0[1] - 10.0 / 255) < 0.01 })
        }
    }
#endif
