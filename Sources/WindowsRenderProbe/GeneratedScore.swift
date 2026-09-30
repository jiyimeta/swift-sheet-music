/// A large orchestral score written out as MusicXML, the same every time — what the onscreen probe measures
/// against. ssm's own samples are at most a few pages; the reader has to stay smooth on scores of forty.
///
/// 16 parts (treble, alto and bass clefs), 80 measures of 4/4 — about 40 A4 pages, two measures to a system — with a
/// key change every 16 measures and a rotating mix per measure: quarters with chords, beamed eighths under a slur,
/// sixteenths, a half and a rest; a dynamic every 8 measures. No license: it is generated.
enum GeneratedScore {
    static let partCount = 16
    static let measureCount = 80

    private static let names = [
        "Flute", "Oboe", "Clarinet", "Bassoon", "Horn", "Trumpet", "Trombone", "Tuba",
        "Timpani", "Violin I", "Violin II", "Viola", "Violoncello", "Contrabass", "Harp", "Piano",
    ]

    private enum Clef {
        case treble, alto, bass

        var sign: (String, Int) {
            switch self {
            case .treble: ("G", 2)
            case .alto: ("C", 3)
            case .bass: ("F", 4)
            }
        }

        /// The octave of the pattern's lowest step, keeping the notes on and around the staff.
        var octave: Int {
            switch self {
            case .treble: 4
            case .alto: 3
            case .bass: 2
            }
        }
    }

    private static func clef(ofPart part: Int) -> Clef {
        switch names[part] {
        case "Bassoon", "Trombone", "Tuba", "Timpani", "Violoncello", "Contrabass": .bass
        case "Viola": .alto
        default: .treble
        }
    }

    static func musicXML() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
        <work><work-title>Generated orchestral score</work-title></work>
        <part-list>

        """
        for part in 0 ..< partCount {
            xml += "<score-part id=\"P\(part + 1)\"><part-name>\(names[part])</part-name></score-part>\n"
        }
        xml += "</part-list>\n"
        for part in 0 ..< partCount {
            xml += "<part id=\"P\(part + 1)\">\n"
            for measure in 0 ..< measureCount {
                xml += measureXML(part: part, measure: measure)
            }
            xml += "</part>\n"
        }
        xml += "</score-partwise>\n"
        return xml
    }

    private static func measureXML(part: Int, measure: Int) -> String {
        var xml = "<measure number=\"\(measure + 1)\">\n"
        let clef = clef(ofPart: part)
        if measure % 16 == 0 {
            let fifths = [0, 2, -3, 4, -1, 1, -2, 3][(measure / 16) % 8]
            xml += "<attributes>"
            if measure == 0 { xml += "<divisions>4</divisions>" }
            xml += "<key><fifths>\(fifths)</fifths></key>"
            if measure == 0 {
                let (sign, line) = clef.sign
                xml += "<time><beats>4</beats><beat-type>4</beat-type></time>"
                xml += "<clef><sign>\(sign)</sign><line>\(line)</line></clef>"
            }
            xml += "</attributes>\n"
        }
        if measure % 8 == 0 {
            let dynamic = ["p", "mf", "f", "pp", "ff", "mp"][(measure / 8 + part) % 6]
            xml += "<direction placement=\"below\"><direction-type><dynamics><\(dynamic)/></dynamics></direction-type>"
            xml += "</direction>\n"
        }
        let base = (part * 3 + measure) % 7
        switch (part + measure) % 4 {
        case 0:
            // Four quarters, the first with a third and a fifth above it.
            for beat in 0 ..< 4 {
                xml += note(step: base + beat, clef: clef, duration: 4, type: "quarter")
                if beat == 0 {
                    xml += note(step: base + 2, clef: clef, duration: 4, type: "quarter", chord: true)
                    xml += note(step: base + 4, clef: clef, duration: 4, type: "quarter", chord: true)
                }
            }
        case 1:
            // Eight eighths in two beamed groups, all under one slur.
            for index in 0 ..< 8 {
                let beam = ["begin", "continue", "continue", "end"][index % 4]
                let slur = index == 0 ? "start" : (index == 7 ? "stop" : nil)
                xml += note(step: base + index % 5, clef: clef, duration: 2, type: "eighth", beam: beam, slur: slur)
            }
        case 2:
            // Two quarters, four beamed sixteenths, a quarter.
            xml += note(step: base, clef: clef, duration: 4, type: "quarter")
            xml += note(step: base + 1, clef: clef, duration: 4, type: "quarter")
            for index in 0 ..< 4 {
                let beam = ["begin", "continue", "continue", "end"][index]
                xml += note(step: base + 2 + index, clef: clef, duration: 1, type: "16th", beam: beam, beams: 2)
            }
            xml += note(step: base + 3, clef: clef, duration: 4, type: "quarter")
        default:
            // A half, a quarter, a quarter rest.
            xml += note(step: base, clef: clef, duration: 8, type: "half")
            xml += note(step: base + 4, clef: clef, duration: 4, type: "quarter")
            xml += "<note><rest/><duration>4</duration><type>quarter</type></note>\n"
        }
        return xml + "</measure>\n"
    }

    private static func note(
        step: Int, clef: Clef, duration: Int, type: String, chord: Bool = false, beam: String? = nil,
        beams: Int = 1, slur: String? = nil,
    ) -> String {
        let steps = ["C", "D", "E", "F", "G", "A", "B"]
        var xml = "<note>"
        if chord { xml += "<chord/>" }
        xml += "<pitch><step>\(steps[step % 7])</step><octave>\(clef.octave + step / 7)</octave></pitch>"
        xml += "<duration>\(duration)</duration><type>\(type)</type>"
        if let beam {
            for number in 1 ... beams {
                xml += "<beam number=\"\(number)\">\(beam)</beam>"
            }
        }
        if let slur {
            xml += "<notations><slur type=\"\(slur)\" number=\"1\"/></notations>"
        }
        return xml + "</note>\n"
    }
}
