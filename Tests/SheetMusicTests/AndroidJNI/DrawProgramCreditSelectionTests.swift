#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicEditWire
    @testable import SheetMusicLayout
    import Testing

    /// A selected title-block credit takes the selection tint in the draw program, the way Apple's
    /// `TitleFrameLayerBuilder` fills its layers: the entry `LayoutTitleFrame.creditEntryIndex(for:)` names is
    /// bracketed in the tint and nothing else in the block is. A credit is not a `ScoreItemID`, so it rides the tint
    /// wire as its own optional field. Beside `DrawProgramTextSelectionTests`, which covers the texts an id names.
    struct DrawProgramCreditSelectionTests {
        private let _installApple = TestSupport.installApple

        private static let tintArgb: UInt32 = 0xFFAB_CDEF
        private static let availableWidth: CGFloat = 1200

        // MARK: - Helpers

        private static func score(_ texts: [FrameText]) -> Score {
            let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            return Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
                systemMeasures: [SystemMeasure()],
                titleFrame: ScoreFrame(heightSp: 12, texts: texts),
            )
        }

        private static func titleAndComposer() -> [FrameText] {
            [FrameText(style: .title, text: "My Title"), FrameText(style: .composer, text: "A. Composer")]
        }

        private static func layout(_ texts: [FrameText]) -> LayoutDocument {
            LayoutEngine.layout(
                score: score(texts), options: ScoreViewOptions(includeTitleFrame: true),
                availableWidth: availableWidth,
            )
        }

        /// The title block's commands with `credit` selected.
        private static func titleCommands(_ frame: LayoutTitleFrame, credit: ScoreInfoWrite.Field?) -> [DrawCommand] {
            var out: [DrawCommand] = []
            LayoutBridge.appendTitleFrame(frame, creditTint: credit.map { (argb: tintArgb, field: $0) }, into: &out)
            return out
        }

        private static func setColorIndices(_ commands: [DrawCommand], argb: UInt32) -> [Int] {
            commands.indices.filter {
                if case let .setColor(a) = commands[$0] { return a == argb }
                return false
            }
        }

        /// The single tint bracket in `commands` — the commands it holds, its close and the program with both
        /// removed — or `nil` when there is not exactly one.
        private static func bracketed(
            _ commands: [DrawCommand],
        ) -> (inner: ArraySlice<DrawCommand>, close: DrawCommand, stripped: [DrawCommand])? {
            let opens = setColorIndices(commands, argb: tintArgb)
            guard opens.count == 1, let open = opens.first,
                  let close = commands[(open + 1)...].firstIndex(where: {
                      if case .setColor = $0 { return true }
                      return false
                  })
            else { return nil }
            var stripped = commands
            stripped.remove(at: close)
            stripped.remove(at: open)
            return (commands[(open + 1) ..< close], commands[close], stripped)
        }

        private static func drawnText(_ commands: ArraySlice<DrawCommand>) -> String {
            commands.compactMap {
                if case let .text(text, _, _, _, _) = $0 { return text }
                return nil
            }.joined()
        }

        // MARK: - The draw program

        @Test("a selected composer's commands sit inside one tint bracket and the title's do not")
        func aSelectedComposerIsBracketed() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let frame = try #require(Self.layout(Self.titleAndComposer()).titleFrame)
            let untinted = Self.titleCommands(frame, credit: nil)
            #expect(Self.drawnText(untinted[...]).contains("My Title"), "control: the title is drawn")

            let tinted = Self.titleCommands(frame, credit: .composer)
            let bracket = try #require(Self.bracketed(tinted))
            #expect(Self.drawnText(bracket.inner) == "A. Composer")
            #expect(bracket.close == .setColor(argb: LayoutBridge.blackARGB))
            #expect(bracket.stripped == untinted)
        }

        @Test("buildCommands brackets the credit it is handed, and no credit leaves the program unchanged")
        func buildCommandsThreadsTheCredit() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.layout(Self.titleAndComposer())
            let untinted = LayoutBridge.buildCommands(layout: doc)
            #expect(LayoutBridge.buildCommands(layout: doc, creditTint: nil) == untinted)

            let tinted = LayoutBridge.buildCommands(layout: doc, creditTint: (argb: Self.tintArgb, field: .title))
            let bracket = try #require(Self.bracketed(tinted))
            #expect(Self.drawnText(bracket.inner) == "My Title")
            #expect(bracket.close == .setColor(argb: LayoutBridge.blackARGB))
            #expect(bracket.stripped == untinted)
        }

        /// The rule `LayoutDocument.creditTextLine(for:)` applies: a credit with no one-line text on the block (none
        /// engraved, no title-block style, or a multi-line block) is not one a tap can select, so none is tinted.
        @Test("a credit with no one-line engraved text leaves the title block unchanged")
        func aCreditWithoutAOneLineTextTintsNothing() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = Self.layout(Self.titleAndComposer())
            let frame = try #require(doc.titleFrame)
            let untinted = Self.titleCommands(frame, credit: nil)
            for credit: ScoreInfoWrite.Field in [.lyricist, .arranger] {
                #expect(doc.creditTextLine(for: credit) == nil, "control: no \(credit) line")
                #expect(Self.titleCommands(frame, credit: credit) == untinted, "\(credit)")
            }

            let multiDoc = Self.layout([
                FrameText(style: .title, text: "My Title"),
                FrameText(style: .composer, text: "Line one\nLine two"),
            ])
            let multi = try #require(multiDoc.titleFrame)
            #expect(multiDoc.creditTextLine(for: .composer) == nil, "control: no one-line composer")
            #expect(Self.titleCommands(multi, credit: .composer) == Self.titleCommands(multi, credit: nil))
        }

        // MARK: - The tint wire

        @Test("the tint wire round-trips a credit, and a payload without one is the old payload")
        func tintWireCarriesTheCredit() throws {
            // One id: a set encodes in an unspecified order, so only a one-element set compares byte for byte.
            let ids: Set<ScoreItemID> = [.clef(.staffDefault(StaffAddress(partIndex: 0, staffIndexInPart: 0)))]
            let withCredit = SelectionTintCodec.encode(argb: Self.tintArgb, ids: ids, credit: .composer)
            let decoded = try SelectionTintCodec.decodeWithCredit(withCredit)
            #expect(decoded.argb == Self.tintArgb)
            #expect(decoded.ids == ids)
            #expect(decoded.credit == .composer)

            let old = SelectionTintCodec.encode(argb: Self.tintArgb, ids: ids)
            #expect(SelectionTintCodec.encode(argb: Self.tintArgb, ids: ids, credit: nil) == old)
            #expect(withCredit != old, "control: the credit is on the wire")
            #expect(try SelectionTintCodec.decodeWithCredit(old).credit == nil)
            #expect(try SelectionTintCodec.decode(withCredit).ids == ids, "the public decode reads it too")

            let unknown = SelectionTintWire(argb: Self.tintArgb, items: [], creditFieldCode: -1).encodeToData()
            #expect(try SelectionTintCodec.decodeWithCredit(unknown).credit == nil)
        }

        /// End to end through the JNI entry point: a credit selection carries no ids, so the credit has to reach the
        /// title block on its own; a payload with no credit, or a code no field has, re-encodes the cached bytes.
        @Test("nativeEncodeDrawProgram tints a credit with no ids beside it")
        func nativeEncodeDrawProgramTintsACreditAlone() throws {
            let handle = scoreTable.insert(Self.score(Self.titleAndComposer()))
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let originalBytes = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                optionsBlob: LayoutOptionsWire.verticalDefault.encodeToData(),
            )
            let original = try #require(try DrawProgramCodec.decode(originalBytes).first?.commands)

            let noCredit = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [])
            #expect(nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: noCredit) == originalBytes)
            let unknown = SelectionTintWire(argb: Self.tintArgb, items: [], creditFieldCode: -1).encodeToData()
            #expect(nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: unknown) == originalBytes)

            let credited = nativeEncodeDrawProgram(
                scoreHandle: handle,
                selectionBytes: SelectionTintCodec.encode(argb: Self.tintArgb, ids: [], credit: .composer),
            )
            let commands = try #require(try DrawProgramCodec.decode(credited).first?.commands)
            let bracket = try #require(Self.bracketed(commands))
            #expect(Self.drawnText(bracket.inner) == "A. Composer")
            #expect(bracket.stripped == original)
        }
    }
#endif
