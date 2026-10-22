#if os(macOS)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicXMLTools
    import Testing

    /// MuseScore's custom notehead group: a drum the kit draws with its own SMuFL glyph per duration. The `<Drum>`
    /// spells it as `<head>normal</head>` plus `<noteheads>` (the normal head is for MuseScore 2.x), and its notes as
    /// `<head>custom</head>`, which MuseScore resolves through the kit (`Note::noteHead`). The stock Drumset's China
    /// cymbal is one. Both halves used to be lost: the kit kept `normal`, the note drew a plain black head, and a save
    /// wrote the drum back without its glyphs.
    @Suite("MSCX custom drum noteheads")
    struct MSCXCustomDrumNoteheadTests {
        private let _installApple = TestSupport.installApple

        /// The stock Drumset's China cymbal and ride, as `share/instruments/instruments.xml` writes them.
        private static let kit = """
        <Instrument id="drumset">
          <useDrumset>1</useDrumset>
          <Drum pitch="51">
            <head>cross</head>
            <line>0</line>
            <voice>0</voice>
            <name>Ride Cymbal 1</name>
            <stem>1</stem>
            <shortcut>F</shortcut>
            <panelRow>0</panelRow>
            <panelColumn>5</panelColumn>
            </Drum>
          <Drum pitch="52">
            <head>normal</head>
            <noteheads>
              <quarter>noteheadHeavyXHat</quarter>
              <half>noteheadHeavyXHat</half>
              <whole>noteheadHeavyXHat</whole>
              <breve>noteheadHeavyXHat</breve>
              </noteheads>
            <line>-3</line>
            <voice>0</voice>
            <name>China Cymbal</name>
            <stem>1</stem>
            <variants>
              <variant pitch="53"><articulation>accent</articulation></variant>
              </variants>
            <panelRow>2</panelRow>
            <panelColumn>3</panelColumn>
            </Drum>
          </Instrument>
        """

        private static func decodedKit() throws -> Instrument {
            try Instrument.decode(XMLTreeParser.parse(Data(kit.utf8)))
        }

        @Test("<noteheads> makes the drum's head the custom group and keeps its glyphs")
        func decodesCustomNoteheads() throws {
            let china = try #require(Self.decodedKit().drumset[52])
            #expect(china.head == "custom")
            #expect(china.noteheads == DrumsetNoteheads(
                whole: "noteheadHeavyXHat", half: "noteheadHeavyXHat",
                quarter: "noteheadHeavyXHat", breve: "noteheadHeavyXHat",
            ))
            #expect(try Self.decodedKit().drumset[51]?.noteheads == nil)
        }

        @Test("a custom drum encodes as MuseScore writes it: a normal head, then its glyphs in duration order")
        func encodesCustomNoteheadsAsMuseScore() throws {
            let encoded = try Self.decodedKit().encode()
            let china = try #require(encoded.all("Drum").first { $0.attributes["pitch"] == "52" })
            #expect(china.children.map(\.name).prefix(3) == ["head", "noteheads", "line"])
            #expect(china.first("head")?.text == "normal")
            #expect(china.first("noteheads")?.children.map(\.name) == ["whole", "half", "quarter", "breve"])
        }

        @Test("a drum's variants and percussion-panel place survive a save")
        func preservesTheRestOfTheDrum() throws {
            let encoded = try Self.decodedKit().encode()
            let drums = encoded.all("Drum")
            let ride = try #require(drums.first { $0.attributes["pitch"] == "51" })
            #expect(ride.first("panelRow")?.text == "0")
            #expect(ride.first("panelColumn")?.text == "5")
            let china = try #require(drums.first { $0.attributes["pitch"] == "52" })
            #expect(china.first("variants")?.first("variant")?.attributes["pitch"] == "53")
            #expect(china.children.map(\.name).suffix(3) == ["variants", "panelRow", "panelColumn"])
            #expect(try Instrument.decode(encoded) == Self.decodedKit())
        }

        @Test("a custom note on the drum staff draws the kit's glyph for its duration")
        func drawsTheKitsGlyph() throws {
            guard #available(macOS 15.0, *) else { return }
            let heads = try Self.laidOutHeads(kit: Self.decodedKit(), durations: [.quarter, .half, .whole])
            let heavyXHat = try #require(SMuFLCodepoint.byName("noteheadHeavyXHat"))
            #expect(heads == [heavyXHat, heavyXHat, heavyXHat])
        }

        @Test("the kit's glyph follows the duration, as MuseScore picks noteheads by head type")
        func glyphFollowsTheDuration() {
            let kit = DrumsetNoteheads(
                whole: "noteheadXWhole", half: "noteheadXHalf", quarter: "noteheadXBlack",
                breve: "noteheadXDoubleWhole",
            )
            func head(_ duration: NoteDuration) -> UInt32 {
                NoteheadGlyph.codepoint(duration: duration, headType: "custom", stemUp: true, kitNoteheads: kit)
            }
            #expect(head(.quarter) == SMuFLCodepoint.byName("noteheadXBlack"))
            #expect(head(.half) == SMuFLCodepoint.byName("noteheadXHalf"))
            #expect(head(.whole) == SMuFLCodepoint.byName("noteheadXWhole"))
            #expect(head(.breve) == SMuFLCodepoint.byName("noteheadXDoubleWhole"))
        }

        @Test("a custom note with no kit to read draws the normal head, as on a pitched staff in MuseScore")
        func customWithoutAKitIsNormal() throws {
            guard #available(macOS 15.0, *) else { return }
            var pitched = try Self.decodedKit()
            pitched.useDrumset = false
            pitched.drumset = [:]
            let heads = try Self.laidOutHeads(kit: pitched, durations: [.quarter])
            #expect(heads == [SMuFLCodepoint.noteheadBlack])
        }

        /// The codepoint each laid-out head of one measure of China-cymbal notes draws, through the renderers' path.
        @available(macOS 15.0, *)
        private static func laidOutHeads(kit: Instrument, durations: [NoteDuration]) throws -> [UInt32] {
            let chords = durations.map { duration in
                VoiceElement.chord(Chord(duration: duration, notes: [Note(pitch: 52, tpc: 14, headType: "custom")]))
            }
            let part = Part(
                id: "drums", instrument: kit,
                staves: [Staff(measures: [Measure(voices: [Voice(elements: IdentifiedArray(chords))])])],
            )
            let doc = LayoutEngine.layout(
                score: Score(division: 480, parts: [part]), options: .init(), availableWidth: 2000,
            )
            return doc.systems[0].measures[0].elements.flatMap { element -> [UInt32] in
                guard case let .chord(notes, duration, stem, _, _, _, _, _, _, _, _) = element else { return [] }
                return notes.map { note in
                    NoteheadGlyph.codepoint(
                        duration: duration, headType: note.headType, stemUp: stem == .up,
                        kitNoteheads: note.kitNoteheads,
                    )
                }
            }
        }
    }
#endif
