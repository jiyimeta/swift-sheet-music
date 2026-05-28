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

    // MARK: - Note

    /// Hiding every `Note` in the score must produce byte-identical SMF.
    ///
    /// Uses `testVoltaTemp.mscx` (24 notes, repeats, 3 tempo changes).
    /// `Note.play` — not `Note.visible` — governs MIDI emission, so
    /// the rendered byte sequence must be unaffected.
    @Test func hidingNotesDoesNotChangeSMFBytes() throws {
        let data = try MSCXFixtureLoader.mscxData("testVoltaTemp")
        let score = try SheetMusic.loadScore(mscxData: data)

        let before = try SheetMusic.exportMIDI(score: score)

        // Build a copy with every Note's visible flag set to false.
        var hidden = score
        var flippedAny = false
        for partIdx in hidden.parts.indices {
            for staffIdx in hidden.parts[partIdx].staves.indices {
                for measureIdx in hidden.parts[partIdx].staves[staffIdx].measures.indices {
                    for voiceIdx in hidden.parts[partIdx].staves[staffIdx]
                        .measures[measureIdx].voices.indices
                    {
                        for elemIdx in hidden.parts[partIdx].staves[staffIdx]
                            .measures[measureIdx].voices[voiceIdx].elements.indices
                        {
                            if case var .chord(chord) = hidden.parts[partIdx]
                                .staves[staffIdx].measures[measureIdx]
                                .voices[voiceIdx].elements[elemIdx]
                            {
                                for noteIdx in chord.notes.indices
                                    where chord.notes[noteIdx].visible
                                {
                                    chord.notes[noteIdx].visible = false
                                    flippedAny = true
                                }
                                hidden.parts[partIdx].staves[staffIdx]
                                    .measures[measureIdx].voices[voiceIdx]
                                    .elements[elemIdx] = .chord(chord)
                            }
                        }
                    }
                }
            }
        }

        #expect(flippedAny, "Fixture must contain at least one visible note")
        #expect(hidden != score, "Mutation must be observable on the Score")

        let after = try SheetMusic.exportMIDI(score: hidden)

        // The invariant: Note.visible never touches SMF bytes.
        #expect(
            before == after,
            "SMF bytes changed after hiding Notes — MidiRenderer must read .play, not .visible",
        )
    }

    // MARK: - Dynamic

    /// Hiding every `Dynamic` in the score must produce byte-identical SMF.
    ///
    /// Uses `testVoltaDynamic.mscx` (3 `<Dynamic>` elements, 24 notes).
    /// A Dynamic's whole purpose is driving MIDI velocity — flipping its
    /// `.visible` flag must never suppress the velocity event it encodes.
    @Test func hidingDynamicsDoesNotChangeSMFBytes() throws {
        let data = try MSCXFixtureLoader.mscxData("testVoltaDynamic")
        let score = try SheetMusic.loadScore(mscxData: data)

        let before = try SheetMusic.exportMIDI(score: score)

        // Build a copy with every Dynamic's visible flag set to false.
        var hidden = score
        var flippedAny = false
        for partIdx in hidden.parts.indices {
            for staffIdx in hidden.parts[partIdx].staves.indices {
                for measureIdx in hidden.parts[partIdx].staves[staffIdx].measures.indices {
                    for voiceIdx in hidden.parts[partIdx].staves[staffIdx]
                        .measures[measureIdx].voices.indices
                    {
                        for elemIdx in hidden.parts[partIdx].staves[staffIdx]
                            .measures[measureIdx].voices[voiceIdx].elements.indices
                        {
                            if case var .dynamic(dynamic) = hidden.parts[partIdx]
                                .staves[staffIdx].measures[measureIdx]
                                .voices[voiceIdx].elements[elemIdx],
                                dynamic.visible
                            {
                                dynamic.visible = false
                                hidden.parts[partIdx].staves[staffIdx]
                                    .measures[measureIdx].voices[voiceIdx]
                                    .elements[elemIdx] = .dynamic(dynamic)
                                flippedAny = true
                            }
                        }
                    }
                }
            }
        }

        #expect(flippedAny, "Fixture must contain at least one visible Dynamic")
        #expect(hidden != score, "Mutation must be observable on the Score")

        let after = try SheetMusic.exportMIDI(score: hidden)

        // The invariant: Dynamic.visible never touches SMF velocity bytes.
        #expect(
            before == after,
            "SMF bytes changed after hiding Dynamics — velocity emission must not depend on .visible",
        )
    }
}
