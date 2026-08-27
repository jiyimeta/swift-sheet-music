@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// The corpus bed for the signature-change intents: every one of them is applied to a score with real content, and
/// the result has to survive a trip through the mscx encoder and back unchanged.
///
/// The suites next door (`SetKeySignatureTests`, `SetTimeSignatureTests`) pin what the intents do to the model; this
/// one pins that what they produce is *writable*. The two go together — a re-bar that splits a note across a new
/// barline, ties the halves, and moves a spanner endpoint is exactly the shape the encoder has the least prior
/// exposure to, because nothing but these commands ever built it.
///
/// A failure here is an encoder/decoder gap, never a reason to soften the seed.
@Suite("Signature changes survive an mscx round trip")
struct SignatureChangeRoundTripTests {
    // MARK: - Seed

    /// Piano (two staves) + B♭ clarinet, six 4/4 bars, with content chosen so every entry in the matrix below has
    /// something to break:
    ///
    /// - bar 0: the opening key + time signature over a measure rest (the pickup variant shrinks this bar),
    /// - bar 1: four quarters — plain material that any re-bar has to redistribute,
    /// - bars 2–3: a half note tied ACROSS the barline, so the encoder's cross-bar tie `<location>` emission is
    ///   exercised over a span the re-bar has already moved,
    /// - bar 4: a triplet on the downbeat, then a quarter and a half rest,
    /// - bar 5: a whole note, split by every meter in the matrix.
    ///
    /// The triplet is parked at the head of bar 4 (absolute tick 7680, or 6240 with the pickup) on purpose: a
    /// re-bar refuses outright when a new barline would fall inside a tuplet, and a refusal would make the round
    /// trip below vacuous. Bar 4's downbeat is a column boundary under the 3/4 of `timeSetAndRemoveSurviveMSCX`
    /// and under the 2/4 of `stackedChangesSurvive`, and sits mid-column under the 6/8 — never inside the triplet
    /// in any of them. Every `apply` is asserted, so a seed that drifts out from under that reasoning fails loudly
    /// rather than silently testing an unedited score.
    ///
    /// The opening key is G major rather than C for a reason that is NOT about signature changes: the encoder
    /// deliberately omits a staff-head `<KeySig>` whose concert AND written key are both C — see
    /// `Voice.shouldDropInitialZeroKeySig`, pinned by `MSCXEncoderMS3Tests.initialZeroKeySigOmittedV4`, and mirroring
    /// MuseScore Studio's own writer. Nothing puts that element back on the way in, so a C-major score built in
    /// memory is one element shorter after a round trip on every non-transposing staff. That asymmetry predates
    /// these commands and is orthogonal to them; seeding it here would test it instead of them. See the task report.
    private func seed(pickup: Bool) -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "Corpus", composer: "Me",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G"), .init(clefType: "F")]),
                .init(
                    instrumentID: "clarinet-bb", longName: "Clarinet", shortName: "Cl.",
                    staves: [.init(clefType: "G")],
                    transposeDiatonic: -1, transposeChromatic: -2, gmProgram: 71,
                ),
            ],
            concertKey: 1, timeNumerator: 4, timeDenominator: 4,
            tempoBPM: 96, measureCount: 6,
        ))
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                for (measureIndex, voice) in Self.content().enumerated() {
                    score.parts[partIndex].staves[staffIndex].measures[measureIndex + 1].voices[0] = voice
                }
                if pickup {
                    score.parts[partIndex].staves[staffIndex].measures[0].actualLength =
                        Fraction(numerator: 1, denominator: 4)
                    score.parts[partIndex].staves[staffIndex].measures[0].irregular = true
                }
            }
        }
        return score
    }

    /// Voice 0 of bars 1 through 5 — see `seed(pickup:)` for what each bar is there to prove. Bar 0 keeps the
    /// factory's measure rest behind the opening signatures, so it is not in this list.
    private static func content() -> [Voice] {
        let tripletMember = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
        return [
            // bar 1 — C, D, E, G: diatonic in the seed's G major, so no glyph is owed before the first edit
            Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 74, tpc: 16)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 76, tpc: 18)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 79, tpc: 15)])),
            ]),
            // bar 2 — the half note here is tied into bar 3
            Voice(elements: [
                .rest(duration: .half),
                .chord(Chord(duration: .half, notes: [Note(pitch: 72, tpc: 14, tieForward: 1)])),
            ]),
            // bar 3 — the tie's far end
            Voice(elements: [
                .chord(Chord(duration: .half, notes: [Note(pitch: 72, tpc: 14, tieBack: 1)])),
                .rest(duration: .half),
            ]),
            // bar 4 — a triplet on the downbeat, then plain material
            Voice(
                elements: [
                    .chord(Chord(duration: tripletMember, notes: [Note(pitch: 72, tpc: 14)])),
                    .chord(Chord(duration: tripletMember, notes: [Note(pitch: 74, tpc: 16)])),
                    .chord(Chord(duration: tripletMember, notes: [Note(pitch: 76, tpc: 18)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 79, tpc: 15)])),
                    .rest(duration: .half),
                ],
                tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)],
            ),
            // bar 5
            Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))]),
        ]
    }

    /// `source` is loader-set metadata (which file format we read), not score content — the same normalization
    /// `BlankScoreTests.roundTrip()` and `MSCXRoundTripTests` apply. Everything else must match exactly.
    private func roundTrip(_ score: Score) throws -> Score {
        try MSCXParser.parse(MSCXEncoder.encode(score)).withSource(.unknown)
    }

    // MARK: - Matrix

    @Test("set then remove a mid-piece key signature", arguments: [false, true])
    func keySetAndRemoveSurviveMSCX(pickup: Bool) throws {
        let session = ScoreEditSession(score: seed(pickup: pickup))
        #expect(session.apply(.setKeySignature(measureIndex: 2, concertKey: -2)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
        #expect(session.apply(.removeKeySignature(measureIndex: 2)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
    }

    @Test("set then remove a mid-piece time signature", arguments: [false, true])
    func timeSetAndRemoveSurviveMSCX(pickup: Bool) throws {
        let session = ScoreEditSession(score: seed(pickup: pickup))
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 3, denominator: 4)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
        #expect(session.apply(.removeTimeSignature(measureIndex: 1)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
    }

    @Test("a meter change, a key change on top of it, and a second meter change downstream")
    func stackedChangesSurvive() throws {
        let session = ScoreEditSession(score: seed(pickup: false))
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 6, denominator: 8)))
        #expect(session.apply(.setKeySignature(measureIndex: 0, concertKey: 4)))
        #expect(session.apply(.setTimeSignature(measureIndex: 2, numerator: 2, denominator: 4)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
    }
}
