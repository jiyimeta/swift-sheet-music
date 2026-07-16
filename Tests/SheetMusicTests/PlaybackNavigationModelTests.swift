import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import SheetMusicXMLTools
import Testing

/// Model + MSCX/MusicXML decode/encode coverage for the navigation
/// fields the jump-aware playback unroll consumes:
/// `Jump.playRepeats`, `Measure.sectionBreak`, `Marker` label
/// defaulting / right-marker classification, and `Spanner` volta
/// ending helpers.
struct PlaybackNavigationModelTests {
    // MARK: - Jump.playRepeats

    @Test func jumpPlayRepeatsDefaultsToFalse() {
        // MuseScore default: Jump::Jump sets m_playRepeats = false
        // (jump.cpp:73).
        let jump = Jump(jumpTo: "start", playUntil: "end")
        #expect(jump.playRepeats == false)
    }

    @Test func decodesJumpPlayRepeatsFromMSCX() throws {
        let xml = """
        <Measure>
          <voice></voice>
          <Jump>
            <jumpTo>segno</jumpTo>
            <playUntil>coda</playUntil>
            <continueAt>codab</continueAt>
            <playRepeats>1</playRepeats>
            <text>D.S. al Coda</text>
          </Jump>
        </Measure>
        """
        let measure = try Measure.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(measure.jumps == [Jump(
            jumpTo: "segno",
            playUntil: "coda",
            continueAt: "codab",
            playRepeats: true,
            text: "D.S. al Coda",
        )])
    }

    @Test func jumpPlayRepeatsRoundTripsThroughMSCX() throws {
        let original = Measure(
            voices: [Voice(elements: [])],
            jumps: [Jump(
                jumpTo: "start", playUntil: "fine",
                playRepeats: true, text: "D.C. al Fine",
            )],
        )
        let encoded = try original.encode()
        let reparsed = try XMLTreeParser.parse(XMLTreeSerializer.serialize(encoded))
        let decoded = try Measure.decode(reparsed)
        #expect(decoded.jumps == original.jumps)
        // Default-false jumps stay tag-free (fixture byte stability).
        let plain = Measure(
            voices: [Voice(elements: [])],
            jumps: [Jump(jumpTo: "start", playUntil: "end")],
        )
        let plainNode = try plain.encode()
        let jumpNode = try #require(plainNode.first("Jump"))
        #expect(jumpNode.all("playRepeats").isEmpty)
    }

    // MARK: - Measure.sectionBreak

    @Test func decodesSectionBreakFromLayoutBreak() throws {
        let xml = """
        <Measure>
          <voice></voice>
          <LayoutBreak>
            <subtype>section</subtype>
          </LayoutBreak>
        </Measure>
        """
        let measure = try Measure.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(measure.sectionBreak == true)
        #expect(measure.lineBreak == false)
        #expect(measure.pageBreak == false)
    }

    @Test func sectionBreakRoundTripsThroughMSCX() throws {
        let original = Measure(voices: [Voice(elements: [])], sectionBreak: true)
        let encoded = try original.encode()
        let reparsed = try XMLTreeParser.parse(XMLTreeSerializer.serialize(encoded))
        let decoded = try Measure.decode(reparsed)
        #expect(decoded.sectionBreak == true)
        // Default-false measures stay LayoutBreak-free.
        let plainNode = try Measure(voices: [Voice(elements: [])]).encode()
        #expect(plainNode.all("LayoutBreak").isEmpty)
    }
}
