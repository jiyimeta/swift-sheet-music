import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML

/// Minimal MusicXML scores for the `<direction>` tests: 4/4, `<divisions>480</divisions>` (a quarter is 480 ticks, a
/// half 960, a whole 1920), a treble clef on staff 1 and a bass clef on staff 2.
enum DirectionFixtures {
    // MARK: Notes

    static func note(
        _ step: String, octave: Int = 4, duration: Int, type: String, voice: Int = 1, staff: Int? = nil,
        extra: String = "",
    ) -> String {
        let staffTag = staff.map { "<staff>\($0)</staff>" } ?? ""
        return "<note><pitch><step>\(step)</step><octave>\(octave)</octave></pitch><duration>\(duration)</duration>"
            + "<voice>\(voice)</voice><type>\(type)</type>\(staffTag)\(extra)</note>"
    }

    static func quarter(
        _ step: String, octave: Int = 4, voice: Int = 1, staff: Int? = nil, extra: String = "",
    ) -> String {
        note(step, octave: octave, duration: 480, type: "quarter", voice: voice, staff: staff, extra: extra)
    }

    static func half(
        _ step: String, octave: Int = 4, voice: Int = 1, staff: Int? = nil, extra: String = "",
    ) -> String {
        note(step, octave: octave, duration: 960, type: "half", voice: voice, staff: staff, extra: extra)
    }

    static func whole(
        _ step: String, octave: Int = 4, voice: Int = 1, staff: Int? = nil, extra: String = "",
    ) -> String {
        note(step, octave: octave, duration: 1920, type: "whole", voice: voice, staff: staff, extra: extra)
    }

    /// A bar of four quarters, C D E F.
    static var fourQuarters: String {
        ["C", "D", "E", "F"].map { quarter($0) }.joined()
    }

    // MARK: Directions

    static func direction(_ types: String, _ extra: String = "", attributes: String = "") -> String {
        let open = attributes.isEmpty ? "<direction>" : "<direction \(attributes)>"
        return "\(open)<direction-type>\(types)</direction-type>\(extra)</direction>"
    }

    static func words(_ text: String, attributes: String = "") -> String {
        attributes.isEmpty ? "<words>\(text)</words>" : "<words \(attributes)>\(text)</words>"
    }

    // MARK: Documents

    private static func attributes(staves: Int) -> String {
        let stavesTag = staves > 1 ? "<staves>\(staves)</staves>" : ""
        var clefs = "<clef number=\"1\"><sign>G</sign><line>2</line></clef>"
        if staves > 1 { clefs += "<clef number=\"2\"><sign>F</sign><line>4</line></clef>" }
        return "<attributes><divisions>480</divisions><key><fifths>0</fifths></key>"
            + "<time><beats>4</beats><beat-type>4</beat-type></time>\(stavesTag)\(clefs)</attributes>"
    }

    static func data(parts: [(measures: [String], staves: Int)], software: String? = nil) -> Data {
        let list = parts.indices
            .map { "<score-part id=\"P\($0 + 1)\"><part-name>Part \($0 + 1)</part-name></score-part>" }
            .joined()
        let identification = software
            .map { "<identification><encoding><software>\($0)</software></encoding></identification>" } ?? ""
        let bodies = parts.enumerated().map { entry -> String in
            var xml = "<part id=\"P\(entry.offset + 1)\">"
            for (index, body) in entry.element.measures.enumerated() {
                xml += "<measure number=\"\(index + 1)\">"
                if index == 0 { xml += attributes(staves: entry.element.staves) }
                xml += body + "</measure>"
            }
            return xml + "</part>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?><score-partwise version="4.0">\(identification)\
        <part-list>\(list)</part-list>\(bodies)</score-partwise>
        """.utf8)
    }

    static func score(
        measures: [String], staves: Int = 1, software: String? = nil, infer: Bool = true,
    ) throws -> Score {
        let options = MusicXMLImportOptions(inferTextType: infer)
        let document = data(parts: [(measures: measures, staves: staves)], software: software)
        return try MusicXMLParser.parse(document, options: options)
    }

    static func score(parts: [[String]], infer: Bool = true) throws -> Score {
        let options = MusicXMLImportOptions(inferTextType: infer)
        return try MusicXMLParser.parse(data(parts: parts.map { (measures: $0, staves: 1) }), options: options)
    }

    // MARK: Reading a score back

    static func voice(_ score: Score, part: Int = 0, staff: Int = 0, measure: Int = 0, voice: Int = 0) -> Voice {
        score.parts[part].staves[staff].measures[measure].voices[voice]
    }

    static func lane(_ score: Score, measure: Int = 0) -> [PositionedSystemElement] {
        score.systemMeasures[measure].elements.values
    }

    /// Each element with the tick the voice's cursor stands at when it reaches it: a chord advances it by its
    /// duration, a `.locationShift` moves it, everything else sits where it is — the walk every consumer makes.
    static func placed(_ voice: Voice) -> [(tick: Int, element: VoiceElement)] {
        var cursor = 0
        var result: [(tick: Int, element: VoiceElement)] = []
        for element in voice.elements.values {
            switch element {
            case let .locationShift(delta):
                cursor += delta.ticks(division: 480)
            case let .chord(chord):
                result.append((cursor, element))
                cursor += chord.duration.ticks(division: 480)
            default:
                result.append((cursor, element))
            }
        }
        return result
    }

    static func dynamics(in voice: Voice) -> [(tick: Int, dynamic: Dynamic)] {
        placed(voice).compactMap { entry -> (tick: Int, dynamic: Dynamic)? in
            guard case let .dynamic(dynamic) = entry.element else { return nil }
            return (entry.tick, dynamic)
        }
    }

    static func spanners(in voice: Voice) -> [(tick: Int, spanner: Spanner)] {
        placed(voice).compactMap { entry -> (tick: Int, spanner: Spanner)? in
            guard case let .spanner(spanner) = entry.element else { return nil }
            return (entry.tick, spanner)
        }
    }

    static func chordTicks(in voice: Voice) -> [Int] {
        placed(voice).compactMap { entry -> Int? in
            guard case .chord = entry.element else { return nil }
            return entry.tick
        }
    }

    static func jogCount(in voice: Voice) -> Int {
        voice.elements.values.filter { element in
            if case .locationShift = element { return true }
            return false
        }.count
    }
}
