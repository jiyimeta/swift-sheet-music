#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The Android draw program carries a text's authored color, size and bold/italic wherever it already has
    /// an opcode for them: `setColor`, the `.text` command's own size, and `setTextStyle`. The face has no
    /// opcode and is not carried — the same limit a chord symbol has.
    ///
    /// Laid out from the score model and encoded through `buildCommands`, so it exercises the same path the
    /// JNI bridge does, and reads nothing the pre-fix tree did not already expose.
    @Suite("DrawProgram text overrides")
    struct DrawProgramTextOverrideTests {
        private let _installFontMetrics = TestSupport.installFontMetrics

        private static let red = ScoreColor(red: 200, green: 10, blue: 20)
        private static let redARGB: UInt32 = 0xFFC8_0A14
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        private static func commands(
            lyric: Lyric = Lyric(text: "la"),
            lane: [SystemElement] = [],
        ) -> [DrawCommand] {
            let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), lyrics: [lyric])
            let score = Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: lane.map {
                PositionedSystemElement(position: .start, element: $0, originalStaff: staff)
            })])
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 800,
            )
            return LayoutBridge.buildCommands(layout: document)
        }

        private static func colors(_ commands: [DrawCommand]) -> [UInt32] {
            commands.compactMap { if case let .setColor(argb) = $0 { argb } else { nil } }
        }

        private static func styles(_ commands: [DrawCommand]) -> [UInt8] {
            commands.compactMap { if case let .setTextStyle(flags) = $0 { flags } else { nil } }
        }

        private static func size(of text: String, in commands: [DrawCommand]) -> Double? {
            commands.lazy.compactMap { command -> Double? in
                if case let .text(value, _, _, size, _) = command, value == text { size } else { nil }
            }.first
        }

        @Test("a lyric's color and size reach the draw program")
        func lyricColorAndSize() throws {
            var colored = Lyric(text: "la", properties: TextProperties(size: 22))
            colored.elementProperties.color = Self.red
            let plain = Self.commands()
            let styled = Self.commands(lyric: colored)
            #expect(!Self.colors(plain).contains(Self.redARGB))
            #expect(Self.colors(styled).contains(Self.redARGB))
            let plainSize = try #require(Self.size(of: "la", in: plain))
            let styledSize = try #require(Self.size(of: "la", in: styled))
            #expect(styledSize > plainSize * 1.5)
        }

        @Test("a staff text's bold and italic override reaches setTextStyle, and its size the text command")
        func staffTextStyleAndSize() throws {
            let plain = Self.commands(lane: [.staffText(StaffText(text: "dolce"))])
            let styled = Self.commands(lane: [.staffText(StaffText(
                text: "dolce", properties: TextProperties(size: 20, style: [.bold, .italic]),
            ))])
            #expect(Self.styles(plain).isEmpty)
            let both = DrawCommand.TextStyleFlag.bold | DrawCommand.TextStyleFlag.italic
            #expect(Self.styles(styled).contains(both))
            let plainSize = try #require(Self.size(of: "dolce", in: plain))
            let styledSize = try #require(Self.size(of: "dolce", in: styled))
            #expect(styledSize > plainSize * 1.5)
        }

        @Test("a rehearsal mark's style override can clear the role's bold")
        func rehearsalStyleOverride() {
            let plain = Self.commands(lane: [.rehearsalMark(RehearsalMark(text: "A"))])
            let regular = Self.commands(lane: [.rehearsalMark(RehearsalMark(
                text: "A", properties: TextProperties(style: []),
            ))])
            #expect(Self.styles(plain).contains(DrawCommand.TextStyleFlag.bold))
            #expect(!Self.styles(regular).contains(DrawCommand.TextStyleFlag.bold))
        }

        @Test("a tempo marking's color and size reach the draw program")
        func tempoColorAndSize() throws {
            var tempo = Tempo(beatsPerSecond: 2, properties: TextProperties(size: 24))
            tempo.elementProperties.color = Self.red
            let plain = Self.commands(lane: [.tempo(Tempo(beatsPerSecond: 2))])
            let styled = Self.commands(lane: [.tempo(tempo)])
            #expect(!Self.colors(plain).contains(Self.redARGB))
            #expect(Self.colors(styled).contains(Self.redARGB))
            // The text run after the metronome glyph, its separating space already advanced past.
            let plainSize = try #require(Self.size(of: "= 120", in: plain))
            let styledSize = try #require(Self.size(of: "= 120", in: styled))
            #expect(styledSize > plainSize * 1.5)
        }
    }
#endif
