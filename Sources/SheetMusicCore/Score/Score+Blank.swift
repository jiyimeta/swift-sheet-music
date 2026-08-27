/// Everything needed to lay out an empty score: one or more parts, each with its own staves and instrument,
/// a shared key/time/tempo, and N bars of measure rest. The reduced instrument catalog lives in the host —
/// callers pass the instrument fields (id, names, GM program, transposition) directly.
public struct BlankScoreTemplate: Sendable, Equatable {
    public struct StaffPlan: Sendable, Equatable {
        /// MuseScore clef-type token stored into `Staff.defaultClefType` ("G", "F", "G8vb", "C3", "PERC", …).
        public var clefType: String
        /// A drum / unpitched staff: `group` "percussion", MuseScore's `perc5Line` staff type, and no key
        /// signature on the opening measure (percussion has no key).
        public var isPercussion: Bool

        public init(clefType: String, isPercussion: Bool = false) {
            self.clefType = clefType
            self.isPercussion = isPercussion
        }
    }

    /// One instrument's worth of the new score: its identity, how many staves it engraves on, and the
    /// playback wiring (GM program, drum kit, transposition).
    public struct PartPlan: Sendable, Equatable {
        public var instrumentID: String
        public var longName: String?
        public var shortName: String?
        public var staves: [StaffPlan]
        /// mscx `<transposeDiatonic>` — diatonic steps from written to sounding pitch (negative = sounds
        /// lower). Copied verbatim onto the built `Instrument`.
        public var transposeDiatonic: Int
        /// mscx `<transposeChromatic>` — semitones from written to sounding pitch (negative = sounds lower).
        public var transposeChromatic: Int
        /// GM program number written into the part's single `InstrumentChannel`.
        public var gmProgram: Int
        /// A drum kit: `useDrumset` plus `GMPercussion.drumLineMap`. The encoder routes such a part to GM
        /// channel 10 off `useDrumset` alone, so nothing else needs setting here.
        public var isDrums: Bool

        public init(
            instrumentID: String, longName: String? = nil, shortName: String? = nil,
            staves: [StaffPlan], transposeDiatonic: Int = 0, transposeChromatic: Int = 0,
            gmProgram: Int = 0, isDrums: Bool = false,
        ) {
            self.instrumentID = instrumentID
            self.longName = longName
            self.shortName = shortName
            self.staves = staves
            self.transposeDiatonic = transposeDiatonic
            self.transposeChromatic = transposeChromatic
            self.gmProgram = gmProgram
            self.isDrums = isDrums
        }
    }

    public var title: String
    public var composer: String?
    public var parts: [PartPlan]
    /// Half-open part ranges to group under a `.normal` bracket (SATB, string quartet). Ranges that fall
    /// outside `parts` — or that are empty — are ignored rather than trapping.
    public var bracketGroups: [Range<Int>]
    /// -7...7, sharps positive — `KeySignature.concertKey`. Written keys are derived for display; only the
    /// concert key is stored.
    public var concertKey: Int
    public var timeNumerator: Int
    public var timeDenominator: Int
    public var tempoBPM: Double
    public var measureCount: Int
    /// Anacrusis: the actual length of the opening bar when it is shorter (or longer) than the time
    /// signature. `nil` — the default — means every bar follows the time signature, exactly as before this
    /// option existed. `measureCount` counts total bars INCLUDING the pickup, so a 4-bar template with a
    /// pickup is the pickup plus three full bars, not four.
    public var pickup: Fraction?

    public init(
        title: String, composer: String? = nil,
        parts: [PartPlan],
        bracketGroups: [Range<Int>] = [],
        concertKey: Int = 0, timeNumerator: Int = 4, timeDenominator: Int = 4,
        tempoBPM: Double = 120, measureCount: Int = 32,
        pickup: Fraction? = nil,
    ) {
        self.title = title
        self.composer = composer
        self.parts = parts
        self.bracketGroups = bracketGroups
        self.concertKey = concertKey
        self.timeNumerator = timeNumerator
        self.timeDenominator = timeDenominator
        self.tempoBPM = tempoBPM
        self.measureCount = max(1, measureCount)
        self.pickup = pickup
    }
}

extension Measure {
    /// This measure with every key signature dropped from every voice. A percussion staff has no key, so a
    /// drum staff built from a pitched bar chain opens on the time signature alone — the same shape
    /// `MidiImporter` produces for a drum track (`includeKeySignature: !track.isDrums`).
    ///
    /// Tuplet endpoints index into the same element list, so the removal goes through
    /// `MeasureStructure.removeElements(in:where:)`, which remaps them. That is dead weight for the
    /// signatures-plus-measure-rest bars `Score.blank(_:)` builds, but `Part.init(blankPlan:id:measures:)`
    /// invites a caller to pass a real bar chain, where it is not.
    fileprivate func droppingKeySignatures() -> Measure {
        var copy = self
        for index in copy.voices.indices {
            MeasureStructure.removeElements(in: &copy.voices[index]) { element in
                if case .keySignature = element { return true }
                return false
            }
        }
        return copy
    }
}

extension Part {
    /// Builds one part from `plan`: its `Instrument`, its staves, and the brace a multi-staff part carries on
    /// its top staff.
    ///
    /// `measures` is the bar chain every staff starts from, so the caller decides what an empty bar looks
    /// like — `Score.blank(_:)` passes signatures-then-measure-rest, while a command that appends a part to
    /// an existing score passes bars matching the score it joins. A percussion staff gets that chain with
    /// the key signatures stripped: percussion has no key, the same call `MidiImporter` makes for a drum
    /// track.
    ///
    /// Cross-part brackets are NOT applied here: a `.normal` group bracket spans the global staff order and
    /// so can only be resolved once every part's staff count is known. See `Score.blank(_:)`.
    init(
        blankPlan plan: BlankScoreTemplate.PartPlan,
        id: String,
        measures: [Measure],
    ) {
        // A plan with no staves would otherwise produce a part the layout engine cannot place; give it one
        // pitched staff so part indices (and therefore bracket ranges) stay meaningful.
        let staffPlans = plan.staves.isEmpty
            ? [BlankScoreTemplate.StaffPlan(clefType: "G")]
            : plan.staves
        let unpitchedMeasures = staffPlans.contains(where: \.isPercussion)
            ? measures.map { $0.droppingKeySignatures() }
            : []
        let staves = staffPlans.enumerated().map { index, staffPlan in
            Staff(
                staffType: staffPlan.isPercussion ? GMPercussion.staffTypeName : "stdNormal",
                group: staffPlan.isPercussion ? GMPercussion.staffGroup : "pitched",
                lineCount: 5,
                defaultClefType: staffPlan.clefType,
                brackets: index == 0 && staffPlans.count > 1
                    ? [BracketItem(type: .brace, span: staffPlans.count)]
                    : [],
                measures: staffPlan.isPercussion ? unpitchedMeasures : measures,
            )
        }
        self.init(
            id: id,
            instrument: Instrument(
                id: plan.instrumentID,
                longName: plan.longName,
                shortName: plan.shortName,
                trackName: plan.longName,
                channels: [InstrumentChannel(program: plan.gmProgram)],
                useDrumset: plan.isDrums,
                drumLineMap: plan.isDrums ? GMPercussion.drumLineMap : [:],
                transposeDiatonic: plan.transposeDiatonic,
                transposeChromatic: plan.transposeChromatic,
            ),
            staves: staves,
        )
    }
}

extension Score {
    /// Builds an empty, playable, encodable score from `template`. The first measure of every staff carries
    /// the key and time signature (percussion staves the time signature only); every measure holds a single
    /// full-measure rest; `systemMeasures` is created in parallel with the tempo on measure 0.
    ///
    /// A `template.pickup` turns that first measure into an anacrusis on every staff: it declares its own
    /// `actualLength` and is `irregular`, so it drops out of the displayed measure numbering. Its content is
    /// unchanged — the single `.measure` rest resolves against `actualLength` wherever a duration is needed
    /// (`[Measure].effectiveMeasureDurations()`), and the signatures stay where they are.
    ///
    /// Part ids are `"1"`, `"2"`, … in document order — the mscx convention the encoder re-synthesizes
    /// anyway, and unique by construction so hosts can key per-part state off them.
    public static func blank(_ template: BlankScoreTemplate) -> Score {
        let timeSignature = TimeSignature(
            numerator: template.timeNumerator,
            denominator: template.timeDenominator,
        )
        let firstMeasure = Measure(
            voices: [Voice(elements: [
                .keySignature(KeySignature(concertKey: template.concertKey)),
                .timeSignature(timeSignature),
                .rest(duration: .measure),
            ])],
            actualLength: template.pickup,
            irregular: template.pickup != nil,
        )
        let laterMeasure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        let measures = [firstMeasure]
            + Array(repeating: laterMeasure, count: template.measureCount - 1)

        var parts = template.parts.enumerated().map { index, plan in
            Part(blankPlan: plan, id: String(index + 1), measures: measures)
        }
        applyBracketGroups(template.bracketGroups, to: &parts)

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
            parts: parts,
            systemMeasures: systemMeasures,
            metaTags: metaTags,
            titleFrame: ScoreFrame(heightSp: 10, texts: frameTexts),
        )
    }

    /// Anchors one `.normal` bracket per group on the top staff of the group's first part, spanning every
    /// staff the grouped parts contribute. A bracket's `span` counts staves in the GLOBAL staff order (the
    /// convention `filtered(hidingStaves:)` documents), which is why this runs after every part is built.
    ///
    /// A group of a single single-staff part would draw a bracket around one staff — MuseScore itself
    /// suppresses that, and so do we.
    ///
    /// The group bracket goes one `column` further out than anything already on the anchor staff, which in
    /// practice means column 1 when a grand-staff part heads the group. Column is not cosmetic there: a
    /// brace is drawn with its right edge at `staffOriginX - 0.3 sp` extending LEFT
    /// (`StaffRenderer.drawBrace`), while a `.normal` bracket's spine sits at
    /// `staffOriginX - 0.5 sp - column * sp` (`StaffRenderer.bracketSpineX`) — so at column 0 the spine
    /// lands inside the brace glyph. Each column steps the spine one `sp` further left, and the gutter
    /// widens to match (`LayoutEngine.bracketGutterInfo` reports `maxColumn + 1`).
    private static func applyBracketGroups(_ groups: [Range<Int>], to parts: inout [Part]) {
        for group in groups {
            guard group.lowerBound >= 0, group.upperBound <= parts.count, !group.isEmpty else { continue }
            let span = parts[group].reduce(0) { $0 + $1.staves.count }
            guard span > 1, !parts[group.lowerBound].staves.isEmpty else { continue }
            let existing = parts[group.lowerBound].staves[0].brackets
            let column = existing.isEmpty ? 0 : (existing.map(\.column).max() ?? 0) + 1
            parts[group.lowerBound].staves[0].brackets.append(
                BracketItem(type: .normal, span: span, column: column),
            )
        }
    }
}
