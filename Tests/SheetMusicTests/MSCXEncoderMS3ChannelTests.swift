import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 Channel target")
struct MSCXEncoderMS3ChannelTests {
    @Test("v3 default Channel omits <midiPort> and <midiChannel>")
    func v3ChannelOmitsDefaults() throws {
        let chan = InstrumentChannel(midiChannel: nil, midiPort: nil)
        let xml = chan.encode(options: .init(targetVersion: .v3))
        #expect(!xml.children.map(\.name).contains("midiPort"))
        #expect(!xml.children.map(\.name).contains("midiChannel"))
    }

    @Test("v3 zero Channel still omits <midiPort> and <midiChannel>")
    func v3ChannelOmitsZeroDefaults() throws {
        let chan = InstrumentChannel(midiChannel: 0, midiPort: 0)
        let xml = chan.encode(options: .init(targetVersion: .v3))
        #expect(!xml.children.map(\.name).contains("midiPort"))
        #expect(!xml.children.map(\.name).contains("midiChannel"))
    }

    @Test("v4 Channel keeps existing <midiPort> / <midiChannel> emission")
    func v4ChannelKeepsDefaults() throws {
        let chan = InstrumentChannel(midiChannel: 0, midiPort: 0)
        let xml = chan.encode(options: .init(targetVersion: .v4))
        #expect(xml.first("midiPort")?.text == "0")
        #expect(xml.first("midiChannel")?.text == "0")
    }

    @Test("v3 emits Bank MSB and LSB controllers before <program>")
    func v3ChannelEmitsBankMSBAndLSB() throws {
        let chan = InstrumentChannel(bank: 1)
        let xml = chan.encode(options: .init(targetVersion: .v3))
        let names = xml.children.map(\.name)
        let firstControllerIndex = try #require(names.firstIndex(of: "controller"))
        let programIndex = try #require(names.firstIndex(of: "program"))
        #expect(firstControllerIndex < programIndex)

        let controllers = xml.children.filter { $0.name == "controller" }
        let bankMSB = controllers.first { $0.attributes["ctrl"] == "0" }
        let bankLSB = controllers.first { $0.attributes["ctrl"] == "32" }
        #expect(bankMSB?.attributes["value"] == "1")
        #expect(bankLSB?.attributes["value"] == "0")
    }

    @Test("v3 always emits Bank MSB+LSB pair even when bank is 0")
    func v3ChannelEmitsBankPairEvenWhenZero() throws {
        let chan = InstrumentChannel()
        let xml = chan.encode(options: .init(targetVersion: .v3))
        let controllers = xml.children.filter { $0.name == "controller" }
        let bankMSB = controllers.first { $0.attributes["ctrl"] == "0" }
        let bankLSB = controllers.first { $0.attributes["ctrl"] == "32" }
        #expect(bankMSB?.attributes["value"] == "0")
        #expect(bankLSB?.attributes["value"] == "0")
    }

    @Test("v4 Channel emits no Bank MSB and uses ctrl 32 for bank")
    func v4ChannelBankEmissionUnchanged() throws {
        let chan = InstrumentChannel(bank: 5)
        let xml = chan.encode(options: .init(targetVersion: .v4))
        let controllers = xml.children.filter { $0.name == "controller" }
        let ctrls = controllers.compactMap { $0.attributes["ctrl"] }
        #expect(!ctrls.contains("0"))
        let bankCtrl32 = controllers.first { $0.attributes["ctrl"] == "32" }
        #expect(bankCtrl32?.attributes["value"] == "5")
    }
}
