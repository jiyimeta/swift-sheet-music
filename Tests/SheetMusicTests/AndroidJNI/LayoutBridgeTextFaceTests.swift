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
