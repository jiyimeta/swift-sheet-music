import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Coverage for `<visible>` on `Arpeggio` (Task 3.2).
/// Scope: model default, decode from inline `<Arpeggio>` node inside a
/// `<Chord>`. Encode and full round-trip are explicitly out-of-scope
/// (the Chord encoder does not yet serialize `<Arpeggio>`).
struct Phase3ArpeggioTests {
    // MARK: - Model default

    @Test func arpeggioDefaultsVisible() {
        let arp = Arpeggio(subtype: 0)
        #expect(arp.visible == true)
    }

    // MARK: - Decode

    @Test func arpeggioDecodesVisibleFalse() throws {
        let chordNode = XMLTreeNode(
            name: "Chord",
            children: [
                XMLTreeNode(name: "durationType", text: "quarter"),
                XMLTreeNode(name: "Arpeggio", children: [
                    XMLTreeNode(name: "subtype", text: "0"),
                    XMLTreeNode(name: "visible", text: "0"),
                ]),
                XMLTreeNode(name: "Note", children: [
                    XMLTreeNode(name: "pitch", text: "60"),
                    XMLTreeNode(name: "tpc", text: "14"),
                ]),
            ],
        )
        let chord = try Chord.decode(chordNode)
        #expect(chord.arpeggio?.visible == false)
    }

    @Test func arpeggioDecodesVisibleTrueWhenTagAbsent() throws {
        let chordNode = XMLTreeNode(
            name: "Chord",
            children: [
                XMLTreeNode(name: "durationType", text: "quarter"),
                XMLTreeNode(name: "Arpeggio", children: [
                    XMLTreeNode(name: "subtype", text: "1"),
                ]),
                XMLTreeNode(name: "Note", children: [
                    XMLTreeNode(name: "pitch", text: "60"),
                    XMLTreeNode(name: "tpc", text: "14"),
                ]),
            ],
        )
        let chord = try Chord.decode(chordNode)
        #expect(chord.arpeggio?.visible == true)
    }
}

// MARK: - Layout honoring (Apple-only: needs CoreGraphics + SheetMusicLayout)

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicLayout

    /// Exercises layout-level visibility routing for `Arpeggio`
    /// (Recipe C: wiggle emission gated by `arpeggio.visible` and
    /// `showsInvisibleElements`).
    struct Phase3ArpeggioLayoutTests {
        private let _installApple = TestSupport.installApple

        /// Build the smallest valid one-measure score whose single chord
        /// carries an arpeggio with controllable visibility.
        private func scoreWithArpeggioChord(arpeggioVisible: Bool) -> Score {
            var arp = Arpeggio(subtype: 0)
            arp.visible = arpeggioVisible
            let note = Note(pitch: 60, tpc: 14)
            var chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            chord.arpeggio = arp
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord),
            ])
            let measure = Measure(voices: [voice])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [measure])],
                )],
            )
        }

        @Test func hiddenArpeggioDroppedWhenToggleOff() {
            let doc = LayoutEngine.layout(
                score: scoreWithArpeggioChord(arpeggioVisible: false),
                options: ScoreViewOptions(showsInvisibleElements: false),
                availableWidth: 800,
            )
            let wiggles = doc.systems.flatMap(\.measures).flatMap(\.elements)
                .filter { if case .arpeggioWiggle = $0 { true } else { false } }
            let invisibleWiggles = doc.systems.flatMap(\.measures).flatMap(\.invisibleElements)
                .filter { if case .arpeggioWiggle = $0 { true } else { false } }
            #expect(wiggles.isEmpty)
            #expect(invisibleWiggles.isEmpty)
        }

        @Test func hiddenArpeggioTaggedWhenToggleOn() {
            let doc = LayoutEngine.layout(
                score: scoreWithArpeggioChord(arpeggioVisible: false),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            let wiggles = doc.systems.flatMap(\.measures).flatMap(\.elements)
                .filter { if case .arpeggioWiggle = $0 { true } else { false } }
            let invisibleWiggles = doc.systems.flatMap(\.measures).flatMap(\.invisibleElements)
                .filter { if case .arpeggioWiggle = $0 { true } else { false } }
            #expect(wiggles.isEmpty)
            #expect(invisibleWiggles.count == 1)
        }

        @Test func visibleArpeggioRoutesToMainList() {
            let doc = LayoutEngine.layout(
                score: scoreWithArpeggioChord(arpeggioVisible: true),
                options: ScoreViewOptions(showsInvisibleElements: true),
                availableWidth: 800,
            )
            let wiggles = doc.systems.flatMap(\.measures).flatMap(\.elements)
                .filter { if case .arpeggioWiggle = $0 { true } else { false } }
            let invisibleWiggles = doc.systems.flatMap(\.measures).flatMap(\.invisibleElements)
                .filter { if case .arpeggioWiggle = $0 { true } else { false } }
            #expect(wiggles.count == 1)
            #expect(invisibleWiggles.isEmpty)
        }
    }
#endif
