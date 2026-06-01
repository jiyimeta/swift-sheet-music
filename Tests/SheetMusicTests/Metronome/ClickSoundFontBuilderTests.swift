import Foundation
@testable import SheetMusicAudioCore
import Testing

struct ClickSoundFontBuilderTests {
    private func sampleSf2() -> Data {
        let strong = [Int16](repeating: 1000, count: 10)
        let weak = [Int16](repeating: -1000, count: 20)
        return ClickSoundFontBuilder.build(
            strong: strong, strongRate: 44100, weak: weak, weakRate: 22050,
        )
    }

    @Test func hasRiffSfbkHeader() {
        let sf2 = sampleSf2()
        #expect(Sf2TestSupport.tag(sf2, 0) == "RIFF")
        #expect(Sf2TestSupport.tag(sf2, 8) == "sfbk")
        #expect(Int(Sf2TestSupport.u32(sf2, 4)) == sf2.count - 8)
    }

    @Test func smplChunkHoldsBothSamplesPlusGuards() throws {
        let sf2 = sampleSf2()
        let sdta = try #require(Sf2TestSupport.listPayloadRange(sf2, listType: "sdta"))
        let smpl = try #require(Sf2TestSupport.subchunkPayloadRange(sf2, in: sdta, id: "smpl"))
        let smplCount = smpl.count
        #expect(smplCount == (10 + 46 + 20 + 46) * 2)
    }

    @Test func presetIsBank128() throws {
        let sf2 = sampleSf2()
        let pdta = try #require(Sf2TestSupport.listPayloadRange(sf2, listType: "pdta"))
        let phdr = try #require(Sf2TestSupport.subchunkPayloadRange(sf2, in: pdta, id: "phdr"))
        let bank = Sf2TestSupport.u16(sf2, phdr.lowerBound + 22)
        #expect(bank == 128)
    }

    @Test func hasTwoSampleHeadersPlusTerminal() throws {
        let sf2 = sampleSf2()
        let pdta = try #require(Sf2TestSupport.listPayloadRange(sf2, listType: "pdta"))
        let shdr = try #require(Sf2TestSupport.subchunkPayloadRange(sf2, in: pdta, id: "shdr"))
        #expect(shdr.count == 46 * 3)
        let strongRate = Sf2TestSupport.u32(sf2, shdr.lowerBound + 36)
        #expect(strongRate == 44100)
    }
}
