import Foundation
import SheetMusicCore

extension MidiRenderer {
    // MARK: - Pitch step generation

    /// Pitch offsets from start to (but excluding) end pitch, per MuseScore's
    /// `Glissando::pitchSteps` in `dom/glissando.cpp:162`. The first element
    /// (index 0) is held for the first ~67% of the start chord; subsequent
    /// elements are the intermediate sweep. The end pitch itself plays as the
    /// NEXT chord in the voice, not as part of this sequence.
    static func glissandoPitchOffsets(
        style: Glissando.Style,
        startPitch: Int,
        endPitch: Int,
        keySignature: Int
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
                pcs: Self.whiteKeyPCs
            )
        case .blackKeys:
            return filteredOffsets(
                startPitch: startPitch,
                endPitch: endPitch,
                direction: direction,
                pcs: Self.blackKeyPCs
            )
        case .diatonic:
            return filteredOffsets(
                startPitch: startPitch,
                endPitch: endPitch,
                direction: direction,
                pcs: majorScalePCs(forKeySignature: keySignature)
            )
        case .portamento:
            return [] // Portamento uses pitch-bend, not discrete pitches.
        }
    }

    private static let whiteKeyPCs: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
    private static let blackKeyPCs: Set<Int> = [1, 3, 6, 8, 10]

    private static func filteredOffsets(
        startPitch: Int, endPitch: Int, direction: Int, pcs: Set<Int>
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

    /// Pitch classes of the major scale for the given concert key signature
    /// (sharps positive, flats negative, range -7…+7). For `0` (C major) this
    /// returns `{0,2,4,5,7,9,11}`. This is an approximation of MuseScore's
    /// line-based diatonic logic (`glissando.cpp:222`): we don't track staff
    /// lines, so we use the current key's major scale as the scale set.
    static func majorScalePCs(forKeySignature keySig: Int) -> Set<Int> {
        let tonic = ((7 * keySig) % 12 + 12) % 12
        return Set([0, 2, 4, 5, 7, 9, 11].map { (tonic + $0) % 12 })
    }

    // MARK: - Ease-in / ease-out timing (cubic Bezier)

    /// Returns `segments + 1` monotonically increasing tick offsets from 0 to
    /// `duration`, distributed according to the Bezier transfer curve defined
    /// by `easeIn`/`easeOut` (percent values 0…100). When both are 0 the
    /// distribution is linear. Mirrors `EaseInOut::timeList` in
    /// `dom/easeInOut.cpp:112`.
    static func easeTimeList(
        segments: Int, duration: Int, easeIn: Int, easeOut: Int
    ) -> [Int] {
        precondition(segments >= 1, "segments must be ≥ 1")
        let n = Double(segments)
        let space = Double(duration)
        let eIn = Double(max(0, min(100, easeIn))) / 100.0
        let eOut = Double(max(0, min(100, easeOut))) / 100.0
        var result: [Int] = []
        result.reserveCapacity(segments + 1)
        for i in 0 ... segments {
            let y = Double(i) / n
            let x = (eIn < 1e-9 && eOut < 1e-9) ? y : xFromYBezier(y, easeIn: eIn, easeOut: eOut)
            result.append(Int((x * space).rounded()))
        }
        return result
    }

    /// Cubic Bezier transfer with endpoints (0,0),(1,1) and controls
    /// (easeIn, 0),(1-easeOut, 1). Given Y returns X. Mirrors MuseScore's
    /// `tFromY` + X(t) composition in `dom/easeInOut.cpp:103`.
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
        voiceIndex: Int
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
