import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMSCX
import Testing

@Suite("Text placement carrier MSCX")
struct TextPlacementCarrierMSCXTests {
    @Test(arguments: [MSCXVersion.v3, .v4])
    func allSixCarriersPreserveDisabledAutoplace(version: MSCXVersion) throws {
        let source = Data("""
        <museScore version="4.60"><Score><Division>480</Division>
          <Part><Staff id="1"/><Instrument><trackName>Test</trackName>
            <Channel><program value="0"/></Channel></Instrument></Part>
          <Staff id="1"><Measure><voice>
            <StaffText><text>Staff</text><autoplace>0</autoplace><placement>below</placement></StaffText>
            <RehearsalMark><text>A</text><autoplace>0</autoplace><placement>below</placement></RehearsalMark>
            <Harmony><name>C7</name><autoplace>0</autoplace><placement>below</placement></Harmony>
            <Chord><durationType>whole</durationType><autoplace>0</autoplace><placement>above</placement>
              <Lyrics><text>word</text><autoplace>0</autoplace><placement>above</placement></Lyrics>
              <Note><pitch>60</pitch><tpc>14</tpc><autoplace>0</autoplace><placement>above</placement></Note>
            </Chord>
          </voice></Measure></Staff>
        </Score></museScore>
        """.utf8)
        let score = try MSCXParser.parse(source)
        let encoded = try MSCXEncoder.encode(score, options: MSCXEncoderOptions(targetVersion: version))
        let restored = try MSCXParser.parse(encoded)
        let elements = restored.allStaves[0].staff.measures[0].voices[0].elements
        let chord = try #require(elements.compactMap { if case let .chord(value) = $0 { value } else { nil } }.first)
        let harmony = try #require(elements.compactMap { if case let .harmony(value) = $0 { value } else { nil } }
            .first)
        var properties = [
            chord.elementProperties,
            chord.notes[0].elementProperties,
            chord.lyrics[0].elementProperties,
            harmony.elementProperties,
        ]
        for entry in restored.systemMeasures[0].elements {
            switch entry.element {
            case let .staffText(value): properties.append(value.elementProperties)
            case let .rehearsalMark(value): properties.append(value.elementProperties)
            default: break
            }
        }
        #expect(properties.count == 6)
        #expect(properties.allSatisfy { $0.autoplace == false })
        #expect(chord.preservedMarkup.allSatisfy { $0.name != "autoplace" })
        #expect(chord.notes[0].preservedMarkup.allSatisfy { $0.name != "autoplace" })
        #expect(chord.lyrics[0].preservedMarkup.allSatisfy { $0.name != "autoplace" })
        #expect(harmony.preservedMarkup.allSatisfy { $0.name != "autoplace" })
        #expect(try MSCXEncoder.encode(restored, options: MSCXEncoderOptions(targetVersion: version)) == encoded)
        let xml = try #require(String(data: encoded, encoding: .utf8))
        #expect(xml.components(separatedBy: "<autoplace>").count - 1 == 6)
    }
}
