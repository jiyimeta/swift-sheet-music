@testable import SheetMusicCore
import Testing

/// A key or meter written at a bar that only INHERITS it: declared there rather than refused as a restatement, so it
/// bounds a change written before it — how a host changes only a span (MuseScore's `undoChangeKeySig` /
/// `cmdAddTimeSig` keep such a signature too).
@Suite("Signature declarations at inheriting bars")
struct SignatureDeclarationTests {
    private static let treble = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    // MARK: - Key

    @Test("a key a bar only inherits is written there, and a change before it then stops at it")
    func inheritedKeyIsDeclared() {
        let original = Self.score(concertKey: 1)
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setKeySignature(measureIndex: 2, concertKey: 1)))
        #expect(Self.declaredKey(session.score, staff: 0, measure: 2) == 1)
        #expect(Self.declaredKey(session.score, staff: 1, measure: 2) == 1)
        #expect(session.score.activeKey(staff: Self.treble, measureIndex: 3) == 1)

        #expect(session.apply(.setKeySignature(measureIndex: 1, concertKey: -1)))
        #expect(session.score.activeKey(staff: Self.treble, measureIndex: 1) == -1)
        #expect(session.score.activeKey(staff: Self.treble, measureIndex: 2) == 1)
        #expect(session.score.activeKey(staff: Self.treble, measureIndex: 3) == 1)

        #expect(session.undo())
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("a key the bar already declares is still nothing to apply")
    func declaredKeyPlansToNothing() {
        let session = ScoreEditSession(score: Self.score(concertKey: 1))
        #expect(session.apply(.setKeySignature(measureIndex: 2, concertKey: 1)))
        let declared = session.score
        #expect(!session.apply(.setKeySignature(measureIndex: 2, concertKey: 1)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == declared)
    }

    // MARK: - Meter

    /// Bar 3 is short of its meter on the top staff, as an imported score's bar can be: a re-bar to the very same meter
    /// would still re-partition it — padding it out with a rest (`RebarPlanner`) — where the declaration must leave it,
    /// and every other bar, exactly as it was.
    @Test("a meter a bar only inherits is declared there on every staff, and nothing is re-barred")
    func inheritedMeterIsDeclaredWithoutRebar() {
        var original = Self.score(concertKey: 0)
        original.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[3].voices[0].elements.updateValue(at: 0) {
                    $0 = .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)]))
                }
            }
        }
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 2, numerator: 4, denominator: 4)))
        let declared = session.score
        #expect(MeasureStructure.measureCount(of: declared) == 4)
        #expect(Self.laneEIDs(declared) == Self.laneEIDs(original))
        let common = TimeSignature(numerator: 4, denominator: 4)
        for staff in 0 ..< 2 {
            #expect(Self.declaredMeter(declared, staff: staff, measure: 2) == common)
            for measure in [0, 1, 3] {
                #expect(declared.parts[0].staves[staff].measures[measure] == original.parts[0].staves[staff]
                    .measures[measure])
            }
            let content = Self.content(original, staff: staff, measure: 2)
            #expect(Self.content(declared, staff: staff, measure: 2) == content)
        }

        #expect(session.undo())
        #expect(session.score == original)
        #expect(session.redo())
        #expect(session.score == declared)
    }

    @Test("a meter declared at a span's end keeps a change at its start inside the span")
    func declaredMeterBoundsAnEarlierChange() {
        let original = Self.score(concertKey: 0)
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 2, numerator: 4, denominator: 4)))
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 2, denominator: 4)))
        let score = session.score

        // Bar 1's whole note re-bars into two bars of 2/4; the bars from the declaration on follow untouched.
        #expect(MeasureStructure.measureCount(of: score) == 5)
        #expect(Self.declaredMeter(score, staff: 0, measure: 1) == TimeSignature(numerator: 2, denominator: 4))
        #expect(Self.declaredMeter(score, staff: 0, measure: 3) == TimeSignature(numerator: 4, denominator: 4))
        #expect(Self.content(score, staff: 0, measure: 3) == Self.content(original, staff: 0, measure: 2))
        #expect(Self.content(score, staff: 0, measure: 4) == Self.content(original, staff: 0, measure: 3))
    }

    @Test("a meter the bar already declares is still nothing to apply")
    func declaredMeterPlansToNothing() {
        let session = ScoreEditSession(score: Self.score(concertKey: 0))
        #expect(session.apply(.setTimeSignature(measureIndex: 2, numerator: 4, denominator: 4)))
        let declared = session.score
        #expect(!session.apply(.setTimeSignature(measureIndex: 2, numerator: 4, denominator: 4)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == declared)
    }

    @Test("an inherited meter declared under its symbol keeps the barlines and draws the symbol")
    func inheritedMeterTakesASymbol() {
        let original = Self.score(concertKey: 0)
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.setTimeSignature(measureIndex: 2, numerator: 4, denominator: 4, symbol: .common)))
        #expect(Self.declaredMeter(session.score, staff: 0, measure: 2)?.symbol == .common)
        #expect(Self.laneEIDs(session.score) == Self.laneEIDs(original))
    }

    @Test("a symbol that does not stand for the inherited meter is refused, score untouched")
    func mismatchedSymbolRefusedOnDeclaration() {
        let original = Self.score(concertKey: 0)
        let session = ScoreEditSession(score: original)
        #expect(!session.apply(.setTimeSignature(measureIndex: 2, numerator: 4, denominator: 4, symbol: .cutCommon)))
        #expect(session.lastRefusal?.reason == .timeSignatureSymbolMismatch(
            symbol: .cutCommon, numerator: 4, denominator: 4,
        ))
        #expect(session.score == original)
    }
}

extension SignatureDeclarationTests {
    /// Piano on two staves, 4 bars of 4/4 in `concertKey`, a whole-note C in every bar of both staves.
    private static func score(concertKey: Int) -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G"), .init(clefType: "F")]),
            ],
            concertKey: concertKey, measureCount: 4,
        ))
        for staffIndex in 0 ..< 2 {
            for measure in 0 ..< 4 {
                let slot = measure == 0 ? 2 : 0
                score.parts.updateValue(at: 0) { partValue in
                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                        staffValue.measures[measure].voices[0].elements.updateValue(at: slot) {
                            $0 = .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))
                        }
                    }
                }
            }
        }
        return score
    }

    private static func declaredKey(_ score: Score, staff: Int, measure: Int) -> Int? {
        for element in score.parts[0].staves[staff].measures[measure].voices[0].elements {
            if case let .keySignature(key) = element { return key.concertKey }
        }
        return nil
    }

    private static func declaredMeter(_ score: Score, staff: Int, measure: Int) -> TimeSignature? {
        for element in score.parts[0].staves[staff].measures[measure].voices[0].elements {
            if case let .timeSignature(signature) = element { return signature }
        }
        return nil
    }

    /// One bar's voice 0 with the leading signature run stripped — the timed content alone.
    private static func content(_ score: Score, staff: Int, measure: Int) -> [VoiceElement] {
        Array(score.parts[0].staves[staff].measures[measure].voices[0].elements
            .drop(while: MeasureStructure.isLeadingSignature))
    }

    private static func laneEIDs(_ score: Score) -> [EID] {
        let lane = score.systemMeasures
        return (0 ..< lane.count).map { lane.eid(at: $0) }
    }
}
