import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// Regression lock: flipping `visible` on score elements must never
/// change SMF output. `MidiRenderer` gates note emission on `Note.play`
/// only — visibility is a layout/display concern and is invisible to
/// the MIDI pipeline.
///
/// Task 1.6 will extend this suite with note and dynamic visibility
/// cases once those types carry `elementProperties`.
struct VisibilityMidiInvariantTests {
    // MARK: - Tempo

    /// Hiding every `Tempo` in the score must produce byte-identical SMF.
    ///
    /// Uses `testVoltaTemp.mscx` (3 `<Tempo>` elements) so the fixture
    /// is non-trivial: notes, dynamics, repeats, and multiple tempo
    /// changes all exercise the renderer path.
    @Test func hidingTempoDoesNotChangeSMFBytes() throws {
        let data = try MSCXFixtureLoader.mscxData("testVoltaTemp")
        let score = try SheetMusic.loadScore(mscxData: data)

        let before = try SheetMusic.exportMIDI(score: score)

        // Build a copy with every Tempo's visible flag set to false.
        var hidden = score
        for measureIndex in hidden.systemMeasures.indices {
            for elementIndex in hidden.systemMeasures[measureIndex].elements.indices {
                if case var .tempo(tempo) =
                    hidden.systemMeasures[measureIndex].elements[elementIndex].element
                {
                    tempo.visible = false
                    hidden.systemMeasures[measureIndex].elements[elementIndex].element =
                        .tempo(tempo)
                }
            }
        }

        // Confirm the flip is non-vacuous: at least one Tempo became hidden,
        // and the two Score values are actually different.
        let allTemposHidden = hidden.systemMeasures.allSatisfy { sm in
            sm.elements.allSatisfy { pse in
                if case let .tempo(t) = pse.element { return !t.visible }
                return true
            }
        }
        #expect(allTemposHidden, "Expected every Tempo to be hidden after the flip")
        #expect(hidden != score, "Expected the hidden copy to differ from the original")

        let after = try SheetMusic.exportMIDI(score: hidden)

        // The invariant: visibility never touches SMF bytes.
        #expect(before == after, "SMF bytes changed after hiding Tempo — MidiRenderer must not read .visible")
    }
}
