import Foundation
import SheetMusicCore

extension MidiRenderer {
    // MARK: - Pitch step generation

    /// Pitch offsets from start to (but excluding) end pitch, per MuseScore's
    /// `Glissando::pitchSteps` in `dom/glissando.cpp:162`. The first element
    /// (index 0) is held for the first ~67% of the start chord; subsequent
    /// elements are the intermediate sweep. The end pitch itself plays as the
    /// NEXT chord in the voice, not as part of this sequence.
    ///
    /// `.diatonic` walks the 7-tone PC set implied by the active key
    /// signature via `KeySignature.diatonicPitchClasses`. This is a
    /// pitch-class approximation of MuseScore's line-based diatonic
    /// logic (`engraving/dom/glissando.cpp:222`): we don't track
    /// staff lines, so Tab clef and unusual non-five-line staves
    /// can diverge. Acceptable for v1.
    static func glissandoPitchOffsets(
        style: Glissando.Style,
        startPitch: Int,
        endPitch: Int,
        keySignature: Int,
    ) -> [Int] {
        guard startPitch != endPitch else { return [] }
        let direction = endPitch > startPitch ? 1 : -1
        switch style {
        case .chromatic:
            return stride(from: startPitch, to: endPitch, by: direction).map { $0 - startPitch }
        case .whiteKeys:
            return filteredOffsets(
                startPitch: startPitch,
                endPitch: endPitch,
                direction: direction,
                pcs: Self.whiteKeyPCs,
            )
        case .blackKeys:
            return filteredOffsets(
                startPitch: startPitch,
                endPitch: endPitch,
                direction: direction,
                pcs: Self.blackKeyPCs,
            )
        case .diatonic:
            return filteredOffsets(
                startPitch: startPitch,
                endPitch: endPitch,
                direction: direction,
                pcs: KeySignature(concertKey: keySignature).diatonicPitchClasses,
            )
        case .portamento:
            return [] // Portamento uses pitch-bend, not discrete pitches.
        }
    }

    private static let whiteKeyPCs: Set = [0, 2, 4, 5, 7, 9, 11]
    private static let blackKeyPCs: Set = [1, 3, 6, 8, 10]

    private static func filteredOffsets(
        startPitch: Int, endPitch: Int, direction: Int, pcs: Set<Int>,
    ) -> [Int] {
        var offsets: [Int] = []
        var pitch = startPitch
        while pitch != endPitch {
            let pc = ((pitch % 12) + 12) % 12
            if pcs.contains(pc) { offsets.append(pitch - startPitch) }
            pitch += direction
        }
        return offsets
    }

    // MARK: - Ease-in / ease-out timing (cubic Bezier)

    /// Cubic Bezier transfer with endpoints (0,0),(1,1) and controls
    /// (easeIn, 0),(1-easeOut, 1). Given Y returns X. Mirrors MuseScore's
    /// `tFromY` + X(t) composition in `dom/easeInOut.cpp:103`. Used by the
    /// portamento pitch-bend ramp (`renderPortamento`); the discrete glissando
    /// renderer distributes its steps uniformly and does not consult it.
    static func xFromYBezier(_ y: Double, easeIn: Double, easeOut: Double) -> Double {
        let clamped = max(0, min(1, y))
        // Y(t) = 3*(1-t)*t² + t³; closed-form solve via trig identity.
        let u = 0.5 + cos((4.0 * .pi + acos(1.0 - 2.0 * clamped)) / 3.0)
        let omu = 1.0 - u
        return 3.0 * omu * omu * u * easeIn + 3.0 * omu * u * u * (1.0 - easeOut) + u * u * u
    }

    // MARK: - End-pitch lookup

    /// Find the pitch of the first note of the next chord in the voice,
    /// scanning forward within `voiceElements` first and then into subsequent
    /// measures' same-voice elements. Returns `nil` if no further chord
    /// exists (the glissando caller then renders the start note normally).
    static func glissandoEndPitch(
        voiceElements: [VoiceElement],
        afterElementIndex: Int,
        measures: [Measure],
        measureIndex: Int,
        voiceIndex: Int,
    ) -> Int? {
        for i in (afterElementIndex + 1) ..< voiceElements.count {
            if case let .chord(next) = voiceElements[i], let first = next.notes.first {
                return first.pitch
            }
        }
        for m in (measureIndex + 1) ..< measures.count {
            guard voiceIndex < measures[m].voices.count else { continue }
            for element in measures[m].voices[voiceIndex].elements {
                if case let .chord(next) = element, let first = next.notes.first {
                    return first.pitch
                }
            }
        }
        return nil
    }
}
