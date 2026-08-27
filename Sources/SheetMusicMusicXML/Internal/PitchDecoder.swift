import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Converts MusicXML `<pitch>` elements to MuseScore-style `(midi, tpc)` pairs.
enum PitchDecoder {
    /// Decode a MusicXML `<pitch>` into `(midi, tpc)`. `<step>` is required;
    /// `<octave>` and `<alter>` default to 4 and 0.
    static func decode(_ pitchNode: XMLTreeNode) throws -> (midi: Int, tpc: Int) {
        guard let stepText = pitchNode.first("step")?.text, !stepText.isEmpty else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.pitch.missingStep",
                    message: "MusicXML: <pitch> missing <step>",
                    location: "pitch",
                ),
            )
        }
        let octave = pitchNode.first("octave").flatMap { Int($0.text) } ?? 4
        let alter = pitchNode.first("alter").flatMap { Int(Double($0.text) ?? 0) } ?? 0
        guard let semitoneOffset = stepSemitones[stepText] else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.pitch.unknownStep",
                    message: "MusicXML: unknown <step>\(stepText)</step>",
                    location: "step \(stepText)",
                ),
            )
        }
        guard let naturalTpc = stepTpc[stepText] else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.pitch.unknownStep",
                    message: "MusicXML: unknown <step>\(stepText)</step>",
                    location: "step \(stepText)",
                ),
            )
        }
        let midi = (octave + 1) * 12 + semitoneOffset + alter
        let tpc = naturalTpc + alter * 7
        return (midi, tpc)
    }

    /// Decode a MusicXML `<unpitched>` block (`<display-step>` + `<display-octave>`)
    /// into a MIDI pitch number. Used for percussion notation where the staff
    /// position is purely visual; the actual drum sound is normally selected
    /// via `<midi-unpitched>` on the part's `<score-instrument>` (decoded by
    /// `MusicXMLDrumTable`) — this function is the fallback for parts
    /// without a usable mapping.
    /// Returns a `(midi, tpc)` pair like `decode(pitchNode:)` so callers can
    /// treat unpitched notes uniformly. TPC defaults to the natural TPC of the
    /// display step (no accidentals are meaningful for unpitched notes).
    static func decodeUnpitched(_ unpitchedNode: XMLTreeNode) throws -> (midi: Int, tpc: Int) {
        let stepText = unpitchedNode.first("display-step")?.text ?? "C"
        let octave = unpitchedNode.first("display-octave").flatMap { Int($0.text) } ?? 4
        guard let semitoneOffset = stepSemitones[stepText] else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.unpitched.unknownDisplayStep",
                    message: "MusicXML: unknown <display-step>\(stepText)</display-step>",
                    location: "display-step \(stepText)",
                ),
            )
        }
        let tpc = stepTpc[stepText] ?? 14
        let midi = (octave + 1) * 12 + semitoneOffset
        return (midi, tpc)
    }

    /// Semitone offset inside the octave (C=0).
    private static let stepSemitones: [String: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11,
    ]

    /// MuseScore "tonal pitch class" for the natural step.
    /// Ring of fifths centered on D (tpc 16): F=13, C=14, G=15, D=16, A=17, E=18, B=19.
    /// Adding `alter * 7` moves by a chromatic fifth (Bb = 12, B# = 26).
    private static let stepTpc: [String: Int] = [
        "F": 13, "C": 14, "G": 15, "D": 16, "A": 17, "E": 18, "B": 19,
    ]
}
