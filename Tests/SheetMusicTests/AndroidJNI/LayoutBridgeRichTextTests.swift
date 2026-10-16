#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// The draw program carries a formatted text with the opcodes it already had: each text run a `.text` inside its
    /// own `setTextStyle` pair, each symbol a SMuFL `.glyph`, underline and strike stroked lines. Measured with the
    /// portable table provider Android and the web read.
    ///
    /// Positions are checked against the layout's own `LayoutRichText`: a run lands at
    /// `positionedRuns(at: measureOrigin + elementOrigin, anchor:)` converted to millimetres, with the anchor each kind
    /// is drawn at by the Apple renderers (staff text (0, 1), lyric (0.5, 0.5), rehearsal (0, 1) inside its padding,
    /// markers and jumps by `LayoutRichText.anchor(for:)`).
    @Suite("LayoutBridge rich text")
    struct LayoutBridgeRichTextTests {
        /// Registers Edwin, which `LayoutEngine.layout` asserts a real provider for in DEBUG.
        private let _installApple = TestSupport.installApple

        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        private static let mm = LayoutBridge.ptToMMScale

        private static func tableProvider() throws -> any FontMetricsProvider {
            let url = try #require(TestResources.url(forResource: "sheet-music", withExtension: "smft"))
            return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: url)))
        }

        private static func staffText(_ text: String, _ content: [PreservedTextMarkup.ContentItem]) -> StaffText {
            StaffText(text: text, preservedTextMarkup: PreservedTextMarkup(content: content, derivedText: text))
        }

        private static func score(_ text: StaffText) -> Score {
            let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
            return Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .staffText(text), originalStaff: staff),
            ])])
        }

        private static func render(_ score: Score) throws -> (document: LayoutDocument, commands: [DrawCommand]) {
            try FontMetrics.$scopedProvider.withValue(tableProvider()) {
                let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
                return (document, LayoutBridge.buildCommands(layout: document))
            }
        }

        private static func commands(_ text: StaffText) throws -> [DrawCommand] {
            try render(score(text)).commands
        }

        /// One measure carrying a formatted rehearsal mark, lyric, marker and jump.
        private static let kindsMSCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part><Staff id="1"/><Instrument id="piano"><longName>Piano</longName><trackName>Piano</trackName>
        <Channel><program value="0"/></Channel></Instrument></Part>
        <Staff id="1"><Measure>
        <Marker><style>Repeat Text Right</style><text><b>Fine</b> here</text><label>fine</label>\
        <markerType>fine</markerType></Marker>
        <Jump><text><i>D.C.</i> al Fine</text><jumpTo>start</jumpTo><playUntil>end</playUntil></Jump>
        <voice><TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
        <RehearsalMark><text><b>A</b><i>bis</i></text></RehearsalMark>
        <Chord><durationType>whole</durationType><Lyrics><text><i>Ah</i> oh</text></Lyrics>
        <Note><pitch>72</pitch><tpc>14</tpc></Note></Chord></voice></Measure></Staff></Score></museScore>
        """

        private static func renderKinds() throws -> (document: LayoutDocument, commands: [DrawCommand]) {
            try render(MSCXParser.parse(Data(kindsMSCX.utf8)))
        }

        /// A rich element with its origin in document coordinates (measure origin added, as the bridge does).
        private struct Found {
            let origin: CGPoint
            let rich: LayoutRichText
            let frame: TextFrameType
        }

        private static func find(
            in document: LayoutDocument, _ pick: (LayoutElement) -> (CGPoint, LayoutRichText, TextFrameType)?,
        ) -> Found? {
            for system in document.systems {
                for measure in system.measures {
                    for element in measure.elements + measure.markers + measure.jumps {
                        guard let (origin, rich, frame) = pick(element) else { continue }
                        return Found(
                            origin: CGPoint(
                                x: measure.origin.x + system.origin.x + origin.x,
                                y: measure.origin.y + system.origin.y + origin.y,
                            ),
                            rich: rich, frame: frame,
                        )
                    }
                }
            }
            return nil
        }

        /// Whether the draw program shows the first run of `rich` placed at `origin` by `anchor`: a `.text` of the same
        /// string, or a `.glyph` of the same codepoint, at the same millimetre position.
        private static func drawsFirstRun(
            of rich: LayoutRichText, at origin: CGPoint, anchor: CGPoint, in commands: [DrawCommand],
        ) -> Bool {
            guard let run = rich.positionedRuns(at: origin, anchor: anchor).first else { return false }
            let x = Double(run.baseline.x) * mm
            let y = Double(run.baseline.y) * mm
            return commands.contains { command in
                switch (command, run.content) {
                case let (.text(drawn, cx, cy, _, _), .text(string)):
                    drawn == string && abs(cx - x) < 0.001 && abs(cy - y) < 0.001
                case let (.glyph(drawn, cx, cy, _, _), .symbol(codepoint)):
                    drawn == codepoint && abs(cx - x) < 0.001 && abs(cy - y) < 0.001
                default:
                    false
                }
            }
        }

        private enum Drawn: Equatable {
            case text(String, UInt8)
            case glyph(UInt32)
        }

        /// Each `.text` with the style bits in force, and each `.glyph`.
        private static func drawn(_ commands: [DrawCommand]) -> [Drawn] {
            var style = DrawCommand.TextStyleFlag.none
            var out: [Drawn] = []
            for command in commands {
                switch command {
                case let .setTextStyle(flags): style = flags
                case let .text(text, _, _, _, _): out.append(.text(text, style))
                case let .glyph(codepoint, _, _, _, _): out.append(.glyph(codepoint))
                default: break
                }
            }
            return out
        }

        /// The x of the first `.text` command whose string is `string`.
        private static func textX(_ string: String, in commands: [DrawCommand]) -> Double? {
            for command in commands {
                if case let .text(text, x, _, _, _) = command, text == string { return x }
            }
            return nil
        }

        private static func strokes(_ commands: [DrawCommand]) -> Int {
            commands.count { if case .stroke = $0 { true } else { false } }
        }

        private static func staffTextFound(_ document: LayoutDocument) -> Found? {
            find(in: document) { element in
                guard case let .staffText(_, origin, _, _, _, _, _, _, rich?) = element else { return nil }
                return (origin, rich, .none)
            }
        }

        @Test("a bold run draws inside its own setTextStyle, the rest in the style's weight")
        func boldRun() throws {
            let drawn = try Self.drawn(Self.commands(Self.staffText("Solo ad lib.", [
                .element(.init(name: "b", content: [.characters("Solo")])), .characters(" ad lib."),
            ])))
            #expect(drawn.contains(.text("Solo", DrawCommand.TextStyleFlag.bold)))
            #expect(drawn.contains(.text(" ad lib.", DrawCommand.TextStyleFlag.none)))
            #expect(!drawn.contains(.text("Solo ad lib.", DrawCommand.TextStyleFlag.none)))
        }

        @Test("a symbol run is a SMuFL glyph at the typeset symbol size")
        func symbolRun() throws {
            let (document, commands) = try Self.render(Self.score(Self.staffText("senza ", [
                .characters("senza "), .element(.init(name: "sym", content: [.characters("keyboardPedalPed")])),
            ])))
            let drawn = Self.drawn(commands)
            #expect(drawn.contains(.glyph(0xE650)))
            #expect(drawn.contains(.text("senza ", DrawCommand.TextStyleFlag.none)))

            let found = try #require(Self.staffTextFound(document))
            let symbol = try #require(found.rich.positionedRuns(at: found.origin, anchor: CGPoint(x: 0, y: 1)).first {
                if case .symbol = $0.content { true } else { false }
            })
            let expectedSize = Double(symbol.font.pointSize) * Self.mm
            let glyph = commands.compactMap { command -> (Double, DrawProgram.FontID)? in
                if case let .glyph(0xE650, _, _, size, fontId) = command { (size, fontId) } else { nil }
            }.first
            let (size, fontId) = try #require(glyph)
            #expect(abs(size - expectedSize) < 1e-9)
            #expect(fontId == .smufl)
        }

        @Test("an underline is one more stroked line, as wide as its run, below the baseline, at its thickness")
        func underline() throws {
            let plain = try Self.commands(Self.staffText("under", [
                .element(.init(name: "i", content: [.characters("under")])),
            ]))
            let (document, underlined) = try Self.render(Self.score(Self.staffText("under", [
                .element(.init(name: "u", content: [.characters("under")])),
            ])))
            #expect(Self.strokes(underlined) == Self.strokes(plain) + 1)

            let found = try #require(Self.staffTextFound(document))
            let anchor = CGPoint(x: 0, y: 1)
            let bar = try #require(found.rich.decorations(at: found.origin, anchor: anchor).first)
            let run = try #require(found.rich.positionedRuns(at: found.origin, anchor: anchor).first)
            let advance = try #require(found.rich.lines.first?.runs.first?.advance)
            // Below the baseline (y grows downward) and as wide as the run it underlines.
            #expect(bar.from.y > run.baseline.y)
            #expect(abs(Double(bar.to.x - bar.from.x - advance)) < 1e-6)

            let from = (x: Double(bar.from.x) * Self.mm, y: Double(bar.from.y) * Self.mm)
            let to = (x: Double(bar.to.x) * Self.mm, y: Double(bar.to.y) * Self.mm)
            let width = Double(bar.thickness) * Self.mm
            let emitted = underlined.indices.dropLast(2).contains { index in
                guard case let .moveTo(x0, y0) = underlined[index],
                      case let .lineTo(x1, y1) = underlined[index + 1],
                      case let .stroke(strokeWidth) = underlined[index + 2] else { return false }
                return abs(x0 - from.x) < 1e-6 && abs(y0 - from.y) < 1e-6
                    && abs(x1 - to.x) < 1e-6 && abs(y1 - to.y) < 1e-6 && abs(strokeWidth - width) < 1e-9
            }
            #expect(emitted)
        }

        /// Task 9 draws a staff text's runs at anchor (0, 1): the ink's left edge sits at the element origin, which
        /// is also where the plain text's left edge sits (anchor x 0). So the first run starts where the plain draw
        /// started, and the next run follows it to the right by the first run's advance. Only the second run is
        /// formatted: the block is placed by its ink's left edge, so a bold "S" (another side bearing) or an underline
        /// (a bar starting at the pen) would move the first pen a fraction of a point for that reason alone.
        @Test("a staff text's runs start at the origin the plain text started at, and follow left to right")
        func staffTextRunsKeepTheLayoutAnchor() throws {
            let plain = try Self.commands(StaffText(text: "Solo ad lib."))
            let rich = try Self.commands(Self.staffText("Solo ad lib.", [
                .characters("Solo"), .element(.init(name: "b", content: [.characters(" ad lib.")])),
            ]))
            let plainX = try #require(Self.textX("Solo ad lib.", in: plain))
            let firstX = try #require(Self.textX("Solo", in: rich))
            let secondX = try #require(Self.textX(" ad lib.", in: rich))
            #expect(abs(firstX - plainX) < 0.01)
            #expect(secondX > firstX)
        }

        @Test("a lyric's runs are centered on its origin (0.5, 0.5), not left-anchored")
        func lyricRunsAreCentered() throws {
            let (document, commands) = try Self.renderKinds()
            let found = try #require(Self.find(in: document) { element in
                guard case let .textMark(.lyrics, _, origin, rich?) = element else { return nil }
                return (origin, rich, .none)
            })
            let centered = CGPoint(x: 0.5, y: 0.5)
            let leading = CGPoint(x: 0, y: 1)
            #expect(Self.drawsFirstRun(of: found.rich, at: found.origin, anchor: centered, in: commands))
            // The control: the same run left-anchored lands elsewhere, so the check above tells the anchors apart.
            #expect(!Self.drawsFirstRun(of: found.rich, at: found.origin, anchor: leading, in: commands))
        }

        @Test("a marker's runs use the marker text anchor")
        func markerRunsUseTheMarkerAnchor() throws {
            let (document, commands) = try Self.renderKinds()
            let found = try #require(Self.find(in: document) { element in
                guard case let .marker(_, _, origin, _, rich?, _, _) = element else { return nil }
                return (origin, rich, .none)
            })
            let anchor = LayoutRichText.anchor(for: .forMarker(.fine)) // the fixture's marker is a Fine
            #expect(Self.drawsFirstRun(of: found.rich, at: found.origin, anchor: anchor, in: commands))
        }

        @Test("a jump's runs use the jump anchor")
        func jumpRunsUseTheJumpAnchor() throws {
            let (document, commands) = try Self.renderKinds()
            let found = try #require(Self.find(in: document) { element in
                guard case let .jump(_, origin, _, rich?, _, _) = element else { return nil }
                return (origin, rich, .none)
            })
            let anchor = LayoutRichText.anchor(for: .jump)
            #expect(Self.drawsFirstRun(of: found.rich, at: found.origin, anchor: anchor, in: commands))
            // The control: a left-baseline anchor lands elsewhere when the jump anchor is not (0, 1).
            let leading = CGPoint(x: 0, y: 1)
            if anchor != leading {
                #expect(!Self.drawsFirstRun(of: found.rich, at: found.origin, anchor: leading, in: commands))
            }
        }

        @Test("a rehearsal mark's runs sit inside the padding at (0, 1), and its frame is still stroked")
        func rehearsalRunsSitInsideThePadding() throws {
            let (document, commands) = try Self.renderKinds()
            let found = try #require(Self.find(in: document) { element in
                guard case let .rehearsalMark(_, origin, frame, _, _, _, _, rich?) = element else { return nil }
                return (origin, rich, frame)
            })
            let pad = RehearsalMarkFrame.paddingSp(sp: document.metrics.sp)
            let inside = CGPoint(x: found.origin.x + pad, y: found.origin.y - pad)
            #expect(Self.drawsFirstRun(of: found.rich, at: inside, anchor: CGPoint(x: 0, y: 1), in: commands))
            #expect(!Self.drawsFirstRun(of: found.rich, at: found.origin, anchor: CGPoint(x: 0, y: 1), in: commands))

            try #require(found.frame != .none)
            let frameWidth = Double(RehearsalMarkFrame.strokeWidthSp(sp: document.metrics.sp)) * Self.mm
            #expect(commands.contains { command in
                if case let .stroke(width) = command { abs(width - frameWidth) < 1e-9 } else { false }
            })
        }

        @Test("a codetta is its two coda runs, each a SMuFL glyph where layout put it (F3.6)")
        func codettaRuns() throws {
            let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
            let measure = Measure(voices: [Voice(elements: [.chord(chord)])], markers: [Marker(kind: .codetta)])
            let (document, commands) = try Self.render(Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"), staves: [Staff(measures: [measure])],
            )]))
            let found = try #require(Self.find(in: document) { element in
                guard case let .marker(_, _, origin, _, rich?, _, _) = element else { return nil }
                return (origin, rich, .none)
            })
            let runs = found.rich.positionedRuns(at: found.origin, anchor: LayoutRichText.anchor(for: .marker))
            try #require(runs.count == 2)
            for run in runs {
                let x = Double(run.baseline.x) * Self.mm
                let y = Double(run.baseline.y) * Self.mm
                let drawn = commands.contains { command in
                    guard case let .glyph(codepoint, cx, cy, _, fontId) = command else { return false }
                    return codepoint == 0xE048 && fontId == .smufl && abs(cx - x) < 0.001 && abs(cy - y) < 0.001
                }
                #expect(drawn)
            }
        }

        @Test("a jump's author color brackets its runs, and the ambient black comes back after")
        func jumpColorBracketsItsRuns() throws {
            let (_, commands) = try Self.render(MSCXParser.parse(MSCXFixtureLoader.mscxData("marker-properties")))
            let red = try #require(commands.firstIndex(of: .setColor(argb: 0xFFC8_0000)))
            let next = commands[(red + 1)...].firstIndex { if case .setColor = $0 { true } else { false } }
            let restore = try #require(next)
            #expect(commands[restore] == .setColor(argb: 0xFF00_0000))
            let painted = commands[red ..< restore].contains { command in
                if case let .text(text, _, _, _, _) = command { text == "D.S. al Coda" } else { false }
            }
            #expect(painted)
        }

        @Test("the stream keeps the v9 wire: nothing new to decode")
        func noNewOpcode() throws {
            let commands = try Self.commands(Self.staffText("Solo", [
                .element(.init(name: "b", content: [.characters("Solo")])),
            ]))
            let page = EncodablePage(widthMM: 100, heightMM: 100, commands: commands)
            let encoded = DrawProgramCodec.encode(pages: [page])
            #expect(try DrawProgramCodec.decode(encoded).first?.commands == commands)
            #expect(DrawProgram.version == 9)
        }
    }
#endif
