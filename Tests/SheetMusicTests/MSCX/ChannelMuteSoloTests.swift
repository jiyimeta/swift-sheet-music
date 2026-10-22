import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A channel's mute and solo, as MuseScore 3 writes them (`<Channel><mute>1</mute><solo>1</solo>`) and MuseScore 4
/// still reads as a compatibility setting.
struct ChannelMuteSoloTests {
    private func decode(_ xml: String) throws -> InstrumentChannel {
        try InstrumentChannel.decode(XMLTreeParser.parse(Data(xml.utf8)))
    }

    private func childNames(_ node: XMLTreeNode) -> [String] {
        node.children.map(\.name)
    }

    @Test func decodesMuteAndSolo() throws {
        let channel = try decode(#"<Channel><program value="0"/><mute>1</mute><solo>1</solo></Channel>"#)
        #expect(channel.isMuted)
        #expect(channel.isSoloed)
        #expect(channel.preservedMarkup.isEmpty)
    }

    @Test func absentMeansFalse() throws {
        let channel = try decode(#"<Channel><program value="0"/></Channel>"#)
        #expect(!channel.isMuted)
        #expect(!channel.isSoloed)
    }

    @Test func zeroMeansFalseAndIsNotPreserved() throws {
        let channel = try decode(#"<Channel><program value="0"/><mute>0</mute><solo>0</solo></Channel>"#)
        #expect(!channel.isMuted)
        #expect(!channel.isSoloed)
        #expect(channel.preservedMarkup.isEmpty)
    }

    @Test(arguments: [MSCXVersion.v3, .v4])
    func roundTripWritesOnceEach(version: MSCXVersion) throws {
        let channel = try decode(#"<Channel><program value="40"/><mute>1</mute><solo>1</solo></Channel>"#)
        let encoded = channel.encode(options: MSCXEncoderOptions(targetVersion: version))
        #expect(childNames(encoded).filter { $0 == "mute" }.count == 1)
        #expect(childNames(encoded).filter { $0 == "solo" }.count == 1)
        let reread = try InstrumentChannel.decode(encoded)
        #expect(reread.program == 40)
        #expect(reread.isMuted && reread.isSoloed)
        #expect(!reread.preservedMarkup.contains { $0.name == "mute" || $0.name == "solo" })
    }

    @Test(arguments: [MSCXVersion.v3, .v4])
    func falseIsNotWritten(version: MSCXVersion) {
        let encoded = InstrumentChannel(program: 40).encode(options: MSCXEncoderOptions(targetVersion: version))
        #expect(!childNames(encoded).contains("mute"))
        #expect(!childNames(encoded).contains("solo"))
    }

    @Test func hashDistinguishesMute() {
        var muted = InstrumentChannel()
        muted.isMuted = true
        #expect(muted != InstrumentChannel())
    }
}
