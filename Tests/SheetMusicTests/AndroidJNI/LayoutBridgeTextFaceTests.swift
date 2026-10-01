#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT && SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicLayoutApple
    import Testing

    /// A text command names the face its position was measured in — the provider's `renderingTextFont` answer —
    /// never the text's role. A notation label's x already has its anchor resolved against the measured ink, so a
    /// reader drawing another face puts a right-aligned part label into the staff.
    ///
    /// So the same label comes out differently per provider: the Apple provider measures the system face semibold
    /// and says so; the portable table provider normalizes that request to Edwin regular, and its stream stays the
    /// `textRoman`, no-semibold one Android and the web already read.
    ///
    /// Each test picks its provider with `FontMetrics.$scopedProvider`, a task-local: nothing global is swapped, so
    /// there is nothing to restore and tests running in parallel each see their own.
    @Suite("LayoutBridge text faces")
    struct LayoutBridgeTextFaceTests {
        /// Registers Edwin, which the Apple provider measures the non-label texts of the full layout in.
        private let _installApple = TestSupport.installApple

        private static let semibold = DrawCommand.TextStyleFlag.semibold
        private static let italic = DrawCommand.TextStyleFlag.italic
        private static let neutral = DrawCommand.TextStyleFlag.none

        private static func tableProvider() throws -> any FontMetricsProvider {
            let url = try #require(TestResources.url(forResource: "sheet-music", withExtension: "smft"))
            return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: url)))
        }

        /// Each `.text` command with its face id and the `setTextStyle` bits in force when it is drawn.
        private static func texts(
            _ commands: [DrawCommand],
        ) -> [(text: String, fontId: DrawProgram.FontID, style: UInt8)] {
            var style = neutral
            var out: [(text: String, fontId: DrawProgram.FontID, style: UInt8)] = []
            for command in commands {
                switch command {
                case let .setTextStyle(flags): style = flags
                case let .text(text, _, _, _, fontId): out.append((text, fontId, style))
                default: break
                }
            }
            return out
        }

        private static func label(_ role: NotationTextStyle.Role) -> [DrawCommand] {
            var out: [DrawCommand] = []
            LayoutBridge.encodeNotationText(text: "17", role: role, originX: 30, originY: 40, sp: 7, into: &out)
            return out
        }

        @Test(arguments: [NotationTextStyle.Role.measureNumber, .staffName, .partLabel, .jump, .markerText])
        func appleLabelsNameTheSystemFaceSemibold(role: NotationTextStyle.Role) throws {
            guard #available(macOS 15.0, *) else { return }
            let commands = FontMetrics.$scopedProvider.withValue(AppleFontMetricsProvider()) { Self.label(role) }
            let texts = Self.texts(commands)
            try #require(texts.count == 1)
            #expect(texts[0].fontId == .system)
            #expect(texts[0].style == Self.semibold | (role == .jump ? Self.italic : Self.neutral))
            // The style is restored after the label, so it cannot leak into what the encoder emits next.
            #expect(commands.last == DrawCommand.setTextStyle(flags: Self.neutral))
        }

        /// The portable stream is byte-for-byte what it was before v8, which is what Android and the web read:
        /// `textRoman`, and a state opcode only for the italic jump.
        @Test(arguments: [NotationTextStyle.Role.measureNumber, .staffName, .partLabel, .jump, .markerText])
        func portableLabelsStayTextRomanRegular(role: NotationTextStyle.Role) throws {
            let commands = try FontMetrics.$scopedProvider.withValue(Self.tableProvider()) { Self.label(role) }
            let texts = Self.texts(commands)
            try #require(texts.count == 1)
            #expect(texts[0].fontId == .textRoman)
            if role == .jump {
                #expect(texts[0].style == Self.italic)
                #expect(commands.count == 3)
            } else {
                #expect(texts[0].style == Self.neutral)
                #expect(commands.count == 1)
            }
        }

        /// The same, over a whole layout that carries a part label, the system-head measure number, staff text and
        /// a tempo mark: nothing a table provider measured is named `system`, and no semibold bit is set anywhere.
        @Test
        func aPortableLayoutNamesNoSystemFace() throws {
            let commands = try FontMetrics.$scopedProvider.withValue(Self.tableProvider()) {
                LayoutBridge.buildCommands(layout: Self.labelledLayout())
            }
            let texts = Self.texts(commands)
            #expect(texts.contains { $0.text == "Violin" })
            #expect(texts.contains { $0.text == "1" })
            #expect(texts.contains { $0.text == "dolce" })
            #expect(texts.allSatisfy { $0.fontId != .system })
            #expect(!commands.contains {
                if case let .setTextStyle(flags) = $0 { flags & Self.semibold != 0 } else { false }
            })
        }

        /// …and the Apple provider's layout of the same score names the system face for exactly the labels.
        @Test
        func anAppleLayoutNamesTheSystemFaceForLabelsOnly() throws {
            guard #available(macOS 15.0, *) else { return }
            let commands = FontMetrics.$scopedProvider.withValue(AppleFontMetricsProvider()) {
                LayoutBridge.buildCommands(layout: Self.labelledLayout())
            }
            let texts = Self.texts(commands)
            let violin = try #require(texts.first { $0.text == "Violin" })
            #expect(violin.fontId == .system)
            #expect(violin.style == Self.semibold)
            let number = try #require(texts.first { $0.text == "1" })
            #expect(number.fontId == .system)
            #expect(number.style == Self.semibold)
            let dolce = try #require(texts.first { $0.text == "dolce" })
            #expect(dolce.fontId == .textRoman)
            #expect(dolce.style == Self.neutral)
        }

        // MARK: - Title block

        /// Every line of `titledLayout()`'s title block, in the order the bridge emits them.
        private static let titleLines = ["Sonata", "in C", "Anon.", "Trad.", "arr. A. Player"]

        /// The title block is measured in the face the Apple renderers draw it in (`LayoutTitleFrame.font(size:)`,
        /// the system face, regular), so the Apple provider's stream names that face for every line, with no style
        /// bit — and the line is anchored with that face's width, not Edwin's.
        @Test
        func anAppleTitleBlockNamesTheSystemFace() throws {
            guard #available(macOS 15.0, *) else { return }
            let provider = AppleFontMetricsProvider()
            let scoped = FontMetrics.$scopedProvider
            let (document, commands): (LayoutDocument, [DrawCommand]) = scoped.withValue(provider) {
                let document = Self.titledLayout()
                return (document, LayoutBridge.buildCommands(layout: document))
            }
            let lines = Self.texts(commands).filter { Self.titleLines.contains($0.text) }
            let texts = lines.map(\.text) // outside `#expect`: inside it a key-path map reads as a throwing call
            #expect(texts == Self.titleLines)
            #expect(lines.allSatisfy { $0.fontId == .system && $0.style == Self.neutral })

            // The centered title's left edge is its anchor less half its width in the face it names.
            let frame = try #require(document.titleFrame)
            let title = try #require(frame.texts.first { $0.style == .title })
            let width = Double(provider.typographicWidth(
                text: "Sonata", font: LayoutTitleFrame.font(size: title.fontSize),
            ))
            let x = try #require(Self.textX("Sonata", in: commands))
            #expect(abs(x - (Double(title.position.x) - width / 2) * LayoutBridge.ptToMMScale) < 1e-9)
        }

        /// …and the table provider's is the stream Android and the web read before 4.0.0, byte for byte: every line
        /// `textRoman`, measured and anchored in Edwin regular, which is what the table normalizes the system face to.
        @Test
        func aPortableTitleBlockIsTheEdwinStreamItWas() throws {
            let (current, edwin): ([DrawCommand], [DrawCommand]) = try FontMetrics.$scopedProvider.withValue(
                Self.tableProvider(),
            ) {
                let frame = try #require(Self.titledLayout().titleFrame)
                var out: [DrawCommand] = []
                LayoutBridge.appendTitleFrame(frame, into: &out)
                return (out, Self.edwinTitleBlock(frame))
            }
            let lines = Self.texts(current)
            let texts = lines.map(\.text)
            #expect(texts == Self.titleLines)
            #expect(lines.allSatisfy { $0.fontId == .textRoman && $0.style == Self.neutral })
            #expect(Self.flat(current) == Self.flat(edwin))
        }

        /// A title, a subtitle, a composer and a two-line lyricist credit over one bar of rest.
        private static func titledLayout() -> LayoutDocument {
            let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
                systemMeasures: [SystemMeasure()],
                titleFrame: ScoreFrame(heightSp: 12, texts: [
                    FrameText(style: .title, text: "Sonata"),
                    FrameText(style: .subtitle, text: "in C"),
                    FrameText(style: .composer, text: "Anon."),
                    FrameText(style: .lyricist, text: "Trad.\narr. A. Player"),
                ]),
            )
            return LayoutEngine.layout(
                score: score, options: ScoreViewOptions(includeTitleFrame: true), availableWidth: 800,
            )
        }

        /// The title block as the bridge emitted it before 4.0.0 — measured, anchored and named in Edwin whatever the
        /// provider — kept as the oracle the portable stream must still equal.
        private static func edwinTitleBlock(_ frame: LayoutTitleFrame) -> [DrawCommand] {
            let scale = LayoutBridge.ptToMMScale
            var out: [DrawCommand] = []
            for entry in frame.texts {
                let fontSize = Double(entry.fontSize)
                let font = LayoutFont(face: "Edwin", pointSize: entry.fontSize)
                let ascent = Double(FontMetrics.provider.ascent(font: font))
                let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let lineHeight = fontSize * 1.2
                let posX = Double(entry.position.x)
                let posY = Double(entry.position.y)
                let topY = entry.anchor.isBottom ? posY - Double(lines.count) * lineHeight : posY
                for (index, line) in lines.enumerated() where !line.isEmpty {
                    let width = Double(FontMetrics.provider.typographicWidth(text: line, font: font))
                    let anchorDx: Double = switch entry.anchor.horizontalFraction {
                    case 0: 0
                    case 0.5: -width / 2
                    default: -width
                    }
                    let lineTopY = topY + Double(index) * lineHeight
                    out.append(.text(
                        text: line, x: (posX + anchorDx) * scale, y: (lineTopY + ascent) * scale,
                        size: fontSize * scale, fontId: .textRoman,
                    ))
                }
            }
            return out
        }

        private static func flat(_ commands: [DrawCommand]) -> Data {
            DrawProgramFlat.encode(pages: [EncodablePage(widthMM: 210, heightMM: 297, commands: commands)])
        }

        /// The x of the first `.text` command drawing `string`.
        private static func textX(_ string: String, in commands: [DrawCommand]) -> Double? {
            for command in commands {
                if case let .text(text, x, _, _, _) = command, text == string { return x }
            }
            return nil
        }

        private static func labelledLayout() -> LayoutDocument {
            let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
            let lane: [SystemElement] = [
                .staffText(StaffText(text: "dolce")),
                .tempo(Tempo(beatsPerSecond: 2)),
            ]
            let score = Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "violin", longName: "Violin", shortName: "Vln."),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: lane.map {
                PositionedSystemElement(position: .start, element: $0, originalStaff: staff)
            })])
            return LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 800)
        }
    }
#endif
