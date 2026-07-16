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

    // MARK: - Marker default labels / right classification

    @Test func markerDefaultLabelsMirrorMuseScoreTable() {
        // markerTypeTable (marker.cpp:51-62): SEGNO→"segno",
        // VARSEGNO→"varsegno", CODA→"codab", VARCODA→"varcoda",
        // CODETTA→"codetta", FINE→"fine", TOCODA/TOCODASYM→"coda".
        #expect(Marker(kind: .segno).effectiveLabel == "segno")
        #expect(Marker(kind: .varsegno).effectiveLabel == "varsegno")
        #expect(Marker(kind: .coda).effectiveLabel == "codab")
        #expect(Marker(kind: .varcoda).effectiveLabel == "varcoda")
        #expect(Marker(kind: .codetta).effectiveLabel == "codetta")
        #expect(Marker(kind: .fine).effectiveLabel == "fine")
        #expect(Marker(kind: .toCoda).effectiveLabel == "coda")
        #expect(Marker(kind: .toCodaSym).effectiveLabel == "coda")
        // Explicit labels always win.
        #expect(Marker(kind: .segno, label: "segno2").effectiveLabel == "segno2")
    }

    @Test func rightMarkerClassificationMirrorsMuseScore() {
        // RIGHT_MARKERS (marker.h:87-93): FINE, TOCODA, TOCODASYM
        // (+ DA_CODA / DA_DBLCODA, which our Kind doesn't model).
        #expect(Marker(kind: .fine).isRightMarker)
        #expect(Marker(kind: .toCoda).isRightMarker)
        #expect(Marker(kind: .toCodaSym).isRightMarker)
        #expect(!Marker(kind: .segno).isRightMarker)
        #expect(!Marker(kind: .varsegno).isRightMarker)
        #expect(!Marker(kind: .coda).isRightMarker)
        #expect(!Marker(kind: .codetta).isRightMarker)
    }

    @Test func decodeFillsEmptyMarkerLabelFromKind() throws {
        let xml = """
        <Measure>
          <Marker>
            <markerType>fine</markerType>
            <text>Fine</text>
          </Marker>
          <voice></voice>
        </Measure>
        """
        let measure = try Measure.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(measure.markers == [Marker(kind: .fine, label: "fine", text: "Fine")])
    }

    @Test func decodeKeepsExplicitMarkerLabel() throws {
        let xml = """
        <Measure>
          <Marker>
            <markerType>segno</markerType>
            <label>segno2</label>
            <text><sym>segno</sym></text>
          </Marker>
          <voice></voice>
        </Measure>
        """
        let measure = try Measure.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(measure.markers.first?.label == "segno2")
    }
}
