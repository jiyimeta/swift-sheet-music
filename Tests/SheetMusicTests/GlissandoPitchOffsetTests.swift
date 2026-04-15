import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Unit coverage for `MidiRenderer.glissandoPitchOffsets` — the pitch-step
/// generator shared by chromatic, whiteKeys, blackKeys, and diatonic
/// glissandi. Mirrors MuseScore's `Glissando::pitchSteps`
/// (`dom/glissando.cpp:162`).
@Suite struct GlissandoPitchOffsetTests {
    @Test func chromatic_ascending() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .chromatic, startPitch: 60, endPitch: 64, keySignature: 0
        )
        #expect(offsets == [0, 1, 2, 3])
    }

    @Test func chromatic_descending() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .chromatic, startPitch: 64, endPitch: 60, keySignature: 0
        )
        #expect(offsets == [0, -1, -2, -3])
    }

    @Test func whiteKeys_CtoC() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .whiteKeys, startPitch: 60, endPitch: 72, keySignature: 0
        )
        #expect(offsets == [0, 2, 4, 5, 7, 9, 11])
    }

    @Test func blackKeys_CSharpToCSharp() {
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .blackKeys, startPitch: 61, endPitch: 73, keySignature: 0
        )
        #expect(offsets == [0, 2, 5, 7, 9])
    }

    @Test func diatonic_CMajor_matchesWhiteKeys() {
        let diatonic = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 60, endPitch: 72, keySignature: 0
        )
        let whiteKeys = MidiRenderer.glissandoPitchOffsets(
            style: .whiteKeys, startPitch: 60, endPitch: 72, keySignature: 0
        )
        #expect(diatonic == whiteKeys)
    }

    @Test func diatonic_GMajor_includesFSharpNotF() {
        // G major = {G, A, B, C, D, E, F#}. From G4 (67) to G5 (79) we expect
        // offsets relative to G: {0, 2, 4, 5, 7, 9, 11}.
        let offsets = MidiRenderer.glissandoPitchOffsets(
            style: .diatonic, startPitch: 67, endPitch: 79, keySignature: 1
        )
        #expect(offsets == [0, 2, 4, 5, 7, 9, 11])
    }
}
