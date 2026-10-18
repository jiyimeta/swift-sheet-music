@testable import SheetMusicCore
import Testing

/// A preserved `<Beam>` marker between the chords of a tie chain (design §9.5).
extension FormatRhythmsBarPlannerTests {
    static func beamMarker(visible: Bool) -> VoiceElement {
        .preserved(PreservedXML(name: "Beam", children: [
            PreservedXML(name: "visible", text: visible ? "1" : "0"), PreservedXML(name: "l1", text: "-12"),
        ]))
    }

    @Test("a preserved beam marker before the continuation does not stop the merge, and goes with the chord")
    func beamMarkerIsTransparent() throws {
        let voice = Self.voice([
            Self.note(1, 2), Self.note(1, 8, pitch: 62),
            Self.note(1, 8, pitch: 64, tieForward: true), Self.beamMarker(visible: true),
            Self.note(1, 4, pitch: 64, tieBack: true),
        ])
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:1/2", "C:1/8", "C:3/8"])
        #expect(result.slots[2].identity == .keep(voice.elements.eid(at: 2)))
    }

    @Test("a beam marker that hides its beam still stops the merge; one before an unchanged chain is carried")
    func hiddenBeamMarkerIsAWall() {
        let hidden = Self.voice([
            Self.note(1, 2), Self.note(1, 8, pitch: 62),
            Self.note(1, 8, pitch: 64, tieForward: true), Self.beamMarker(visible: false),
            Self.note(1, 4, pitch: 64, tieBack: true),
        ])
        #expect(Self.respell(hidden) == nil)
        // The note 3/8 at 3/8 is spelled eighth ~ quarter (a dotted quarter would hide beat 3): the chain is already
        // what the splitter writes, nothing changes, and the marker stays where it was.
        let kept = Self.voice([
            Self.note(1, 4), Self.note(1, 8, pitch: 62),
            Self.note(1, 8, pitch: 64, tieForward: true), Self.beamMarker(visible: true),
            Self.note(1, 4, pitch: 64, tieBack: true), Self.note(1, 4, pitch: 65),
        ])
        #expect(Self.respell(kept) == nil)
    }
}
