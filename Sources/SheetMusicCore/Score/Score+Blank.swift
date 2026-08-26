/// Everything needed to lay out an empty score: one part, one or more staves, a key/time/tempo, and N bars of
/// measure rest. The reduced instrument catalog arrives in a later milestone; until then callers pass the
/// instrument fields directly.
public struct BlankScoreTemplate: Sendable, Equatable {
    public struct StaffPlan: Sendable, Equatable {
        /// MuseScore clef-type token stored into `Staff.defaultClefType` ("G", "F", …).
        public var clefType: String
        public init(clefType: String) {
            self.clefType = clefType
        }
    }

    public var title: String
    public var composer: String?
    public var instrumentID: String
    public var instrumentName: String?
    public var staves: [StaffPlan]
    /// -7...7, sharps positive — `KeySignature.concertKey`.
    public var concertKey: Int
    public var timeNumerator: Int
    public var timeDenominator: Int
    public var tempoBPM: Double
    public var measureCount: Int

    public init(
        title: String, composer: String? = nil,
        instrumentID: String, instrumentName: String? = nil,
        staves: [StaffPlan],
        concertKey: Int = 0, timeNumerator: Int = 4, timeDenominator: Int = 4,
        tempoBPM: Double = 120, measureCount: Int = 32,
    ) {
        self.title = title
        self.composer = composer
        self.instrumentID = instrumentID
        self.instrumentName = instrumentName
        self.staves = staves
        self.concertKey = concertKey
        self.timeNumerator = timeNumerator
        self.timeDenominator = timeDenominator
        self.tempoBPM = tempoBPM
        self.measureCount = max(1, measureCount)
    }
}

extension Score {
    /// Builds an empty, playable, encodable score from `template`. The first measure of every staff carries the
    /// key and time signature; every measure holds a single full-measure rest; `systemMeasures` is created in
    /// parallel with the tempo on measure 0.
    public static func blank(_ template: BlankScoreTemplate) -> Score {
        let firstMeasure = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: template.concertKey)),
            .timeSignature(TimeSignature(
                numerator: template.timeNumerator,
                denominator: template.timeDenominator,
            )),
            .rest(duration: .measure),
        ])])
        let laterMeasure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])

        let staves = template.staves.enumerated().map { index, plan in
            Staff(
                defaultClefType: plan.clefType,
                brackets: index == 0 && template.staves.count > 1
                    ? [BracketItem(type: .brace, span: template.staves.count)]
                    : [],
                measures: [firstMeasure] + Array(repeating: laterMeasure, count: template.measureCount - 1),
            )
        }

        var systemMeasures = Array(repeating: SystemMeasure(), count: template.measureCount)
        systemMeasures[0] = SystemMeasure(elements: [PositionedSystemElement(
            position: .start,
            element: .tempo(Tempo(beatsPerSecond: template.tempoBPM / 60.0)),
            // Explicit rather than the `nil` default: the MSCX encoder already treats `nil` as this same
            // canonical staff when placing a system element (`MSCXEncoder+Score.swift`'s
            // `perMeasureSystemElements`), and the decoder always reconstructs it explicitly on re-parse, so
            // writing it here up front keeps a freshly-built score `==` to its own semantic round-trip.
            originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        )])

        var metaTags = ["workTitle": template.title]
        var frameTexts = [FrameText(style: .title, text: template.title)]
        if let composer = template.composer {
            metaTags["composer"] = composer
            frameTexts.append(FrameText(style: .composer, text: composer))
        }

        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: template.instrumentID, longName: template.instrumentName),
                staves: staves,
            )],
            systemMeasures: systemMeasures,
            metaTags: metaTags,
            titleFrame: ScoreFrame(heightSp: 10, texts: frameTexts),
        )
    }
}
