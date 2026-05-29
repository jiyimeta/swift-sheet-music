import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for `<visible>` on Fermata, RehearsalMark, and Lyric
/// (Task 3.1). Each test encodes an element with `visible == false`, re-parses
/// the XML, and asserts the flag survives both directions of the round-trip.
/// Tests also confirm the default (visible) omits the tag entirely, matching
/// MuseScore's own serialization behavior.
struct Phase3RoundTripTests {
    // MARK: - Fermata

    @Test func fermataVisibleFalseEncodes() {
        var fermata = Fermata(subtype: "fermataAbove")
        fermata.visible = false
        let encoded = fermata.encode()
        #expect(encoded.first("visible")?.text == "0")
    }

    @Test func fermataVisibleTrueOmitsTag() {
        let encoded = Fermata(subtype: "fermataAbove").encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    @Test func fermataDecodesVisibleFalseFromInlineVoice() throws {
        // Fermata is decoded inline inside Voice. Build a minimal <Voice> node
        // with a <Fermata visible=false> child and confirm the resulting
        // VoiceElement carries visible == false.
        let fermataNode = XMLTreeNode(
            name: "Fermata",
            children: [
                XMLTreeNode(name: "subtype", text: "fermataAbove"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let voiceNode = XMLTreeNode(
            name: "Voice",
            children: [fermataNode],
        )
        let voice = try Voice.decode(voiceNode)
        guard case let .fermata(fermata) = voice.elements.first else {
            Issue.record("Expected .fermata element")
            return
        }
        #expect(fermata.visible == false)
    }

    // MARK: - RehearsalMark

    @Test func rehearsalMarkVisibleFalseRoundTrips() throws {
        let node = XMLTreeNode(
            name: "RehearsalMark",
            children: [
                XMLTreeNode(name: "text", text: "A"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let mark = try RehearsalMark.decode(node)
        #expect(mark.visible == false)
        let reencoded = mark.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func rehearsalMarkVisibleTrueOmitsTag() {
        let encoded = RehearsalMark(text: "A").encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }

    // MARK: - Lyric

    @Test func lyricVisibleFalseRoundTrips() throws {
        // Lyric is decoded inline inside Chord. Build a minimal <Chord> node
        // with a <Lyrics visible=false> child and confirm the resulting
        // Lyric carries visible == false.
        let lyricsNode = XMLTreeNode(
            name: "Lyrics",
            children: [
                XMLTreeNode(name: "text", text: "la"),
                XMLTreeNode(name: "visible", text: "0"),
            ],
        )
        let chordNode = XMLTreeNode(
            name: "Chord",
            children: [
                XMLTreeNode(name: "durationType", text: "quarter"),
                XMLTreeNode(name: "Note", children: [
                    XMLTreeNode(name: "pitch", text: "60"),
                    XMLTreeNode(name: "tpc", text: "14"),
                ]),
                lyricsNode,
            ],
        )
        let chord = try Chord.decode(chordNode)
        guard let lyric = chord.lyrics.first else {
            Issue.record("Expected at least one lyric")
            return
        }
        #expect(lyric.visible == false)
        let reencoded = lyric.encode()
        #expect(reencoded.first("visible")?.text == "0")
    }

    @Test func lyricVisibleTrueOmitsTag() {
        let encoded = Lyric(text: "la").encode()
        #expect(!encoded.children.contains(where: { $0.name == "visible" }))
    }
}
