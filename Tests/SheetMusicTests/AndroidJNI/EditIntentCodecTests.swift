import Foundation
@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

@Suite("EditIntentCodec")
struct EditIntentCodecTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private static let rest = RestID(staff: staff, measureIndex: 3, voiceIndex: 2, elementIndex: 5)
    private static let slot = VoiceElementID(rest)

    private static let cases: [EditIntent] = [
        .inputNote(at: rest, pitch: 60, tpc: 14, duration: nil),
        .inputNote(at: rest, pitch: 61, tpc: 21, duration: .eighth),
        .inputNote(at: rest, pitch: 62, tpc: 16, duration: .fraction(Fraction(numerator: 3, denominator: 8))),
        .setRestDuration(at: slot, duration: .measure),
        .setChordDuration(at: slot, duration: .whole),
        .delete(at: slot),
        .composite([.delete(at: slot), .setRestDuration(at: slot, duration: .quarter)]),
    ]

    @Test("every intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test("a decoded intent applies exactly as the original does")
    func decodedIntentAppliesIdentically() throws {
        let direct = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let viaWire = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let intent = EditIntent.inputNote(
            at: RestID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 1,
            ),
            pitch: 60, tpc: 14, duration: .half,
        )
        _ = direct.apply(intent)
        _ = try viaWire.apply(EditIntentCodec.decode(EditIntentCodec.encode(intent)))
        #expect(direct.score.stableFingerprint == viaWire.score.stableFingerprint)
    }

    @Test("garbage bytes throw rather than decoding to something plausible")
    func garbageThrows() {
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(Data([0xFF, 0xFF, 0xFF]))
        }
    }

    /// `Fraction.init(numerator:denominator:)` traps on a non-positive denominator — a `precondition`, not a throw
    /// — so a structurally valid TLV payload carrying `kind == 11` (`.fraction`) with `denominator == 0` must never
    /// reach it. This builds exactly that payload by hand-mutating an otherwise-valid wire struct (the public
    /// `EditIntent` API can't construct a malformed `Fraction` to begin with) and encodes it to real bytes, so the
    /// assertion below exercises the actual decode path a corrupted or hostile payload would hit.
    @Test("a fraction duration with a zero denominator is refused, not a crash")
    func fractionDurationWithZeroDenominatorThrows() {
        var durationWire = NoteDurationWire(from: .whole)
        durationWire.kind = 11
        durationWire.denominator = 0
        var slotWire = SlotDurationIntentWire(location: Self.slot, duration: .quarter)
        slotWire.duration = durationWire
        let bytes = EditIntentWire.setRestDuration(slotWire).encodeToData()
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(bytes)
        }
    }

    /// The forward-compatibility guard: a `kind` outside `1...11` is what stops a newer writer's duration from
    /// silently decoding as a *different* duration in an older reader — the exact risk a frozen tag creates. Was
    /// unexercised before this test.
    @Test("an out-of-range duration kind throws rather than decoding as some other duration")
    func outOfRangeDurationKindThrows() {
        var durationWire = NoteDurationWire(from: .whole)
        durationWire.kind = 200
        var slotWire = SlotDurationIntentWire(location: Self.slot, duration: .quarter)
        slotWire.duration = durationWire
        let bytes = EditIntentWire.setRestDuration(slotWire).encodeToData()
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(bytes)
        }
    }

    private static func nestedComposite(levels: Int) -> EditIntent {
        var intent = EditIntent.delete(at: Self.slot)
        for _ in 0 ..< levels {
            intent = .composite([intent])
        }
        return intent
    }

    /// A malformed payload nesting far past what a real composite ever does (production nests at most 2 deep) must
    /// be refused *before* the parse recurses into it, not after.
    ///
    /// The 20 levels here are not a safe margin: on WebAssembly the shadow stack is 128 KiB and one level of this
    /// parse costs 8-10 KiB, so the tree used to run out of stack around level 13. Because wasm-ld puts `.bss`
    /// directly below the stack, that did not trap — it silently overwrote the allocator's state, and the run died
    /// hundreds of tests later inside an unrelated `malloc`. So this test is exactly the crash that already
    /// happened, and it only passes while the bound sits on the parse.
    @Test("a composite nested past the depth limit throws instead of overflowing the stack")
    func deeplyNestedCompositeThrows() {
        let bytes = EditIntentCodec.encode(Self.nestedComposite(levels: 20))
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(bytes)
        }
    }

    /// Pins the limit itself. Without this, moving the bound onto the parse could quietly refuse one level too
    /// early and no other test would notice — every composite the app actually writes is one level deep.
    @Test("the depth limit admits exactly eight levels and refuses the ninth")
    func compositeDepthBoundaryIsEightLevels() throws {
        let atLimit = Self.nestedComposite(levels: 8)
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(atLimit)) == atLimit)

        let pastLimit = EditIntentCodec.encode(Self.nestedComposite(levels: 9))
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(pastLimit)
        }
    }

    // swiftlint:disable:next function_body_length
    @Test func `every new intent round-trips`() throws {
        let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let note = NoteID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3, noteIndexInChord: 1)
        // Distinct from `note` (different `elementIndex`) so `.setTie`'s round trip can actually catch a
        // `source`/`target` field transposition in `SetTieIntentWire` — round-tripping the same `NoteID` on both
        // sides would pass just as well with the two tags swapped.
        let otherNote = NoteID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 4, noteIndexInChord: 0)
        let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)
        // Two distinct bounds, so a `start` / `end` transposition in `VoiceElementRangeWire` cannot round-trip.
        let range = VoiceElementRange(
            start: slot, end: VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 0, elementIndex: 1),
        )
        let intents: [EditIntent] = [
            .setNotePitch(at: note, pitch: 61, tpc: 21, accidental: .sharp),
            .setAccidental(at: note, accidental: nil),
            .addNoteToChord(at: slot, pitch: 64, tpc: 18, accidental: .natural),
            .removeNoteFromChord(at: note),
            .setTie(from: note, to: otherNote, sourceTieForward: 7, targetTieBack: nil),
            .createTuplet(at: slot, actualNotes: 3, normalNotes: 2),
            .removeTuplet(at: slot),
            // SP2's addition. Both duration shapes: `nil` writes the `kind = 1` placeholder with `hasDuration == 0`,
            // and a real duration has to survive alongside it.
            .writeNote(at: slot, pitch: 62, tpc: 16, duration: .eighth),
            .writeNote(at: slot, pitch: 62, tpc: 16, duration: nil),
            // Shares `SlotDurationIntentWire` with `.setRestDuration` / `.setChordDuration`, so the round trip is
            // really checking that the DISCRIMINATOR carries the difference — the payload bytes are identical.
            .writeRest(at: slot, duration: .half),
            // Appended for M1 solo scratch creation — indices 14…15.
            .insertMeasure(at: 3),
            .deleteMeasure(at: 0),
            // Appended for M2 ensemble creation — index 16. Three shapes, because `PartPlanWire` is the first
            // payload in this file carrying strings, an array and two present-flagged optionals: both names set
            // on a transposing single-staff part, both names absent, and a multi-staff drum plan.
            .addPart(
                plan: .init(
                    instrumentID: "clarinet-bb", longName: "Clarinet in B♭", shortName: "Cl.",
                    staves: [.init(clefType: "G")],
                    transposeDiatonic: -1, transposeChromatic: -2, gmProgram: 71,
                ),
                at: 2,
            ),
            .addPart(plan: .init(instrumentID: "x", staves: [.init(clefType: "G")]), at: 0),
            .addPart(
                plan: .init(
                    instrumentID: "drumset", longName: "Drum Kit",
                    staves: [.init(clefType: "PERC", isPercussion: true), .init(clefType: "F")],
                    isDrums: true,
                ),
                at: 1,
            ),
            // Appended for M2 ensemble creation — indices 17…18. `.movePart`'s two fields are distinct so the
            // round trip can catch a `from`/`to` transposition, which would silently move the part the wrong way.
            .removePart(at: 2),
            .movePart(from: 0, to: 3),
            // Appended for M3 signature changes — indices 19…20. A flat key and a sharp one, because `concertKey`
            // is the first field in this codec whose real range is signed: a plain (non-zig-zag) varint would
            // encode -3 as ten bytes and still round-trip, so the pair is here to keep the layout doc honest
            // rather than to catch a decode.
            .setKeySignature(measureIndex: 2, concertKey: -3),
            .setKeySignature(measureIndex: 0, concertKey: 7),
            .removeKeySignature(measureIndex: 5),
            // Indices 21…22. The numerator and denominator are deliberately unequal to each other and to the
            // measure index, so a field written into the wrong tag cannot survive the round trip looking right.
            .setTimeSignature(measureIndex: 3, numerator: 7, denominator: 8),
            // Twice: `symbol` is the fourth field of the same payload, and a regression that dropped it would
            // still round-trip the numeric form — which every other intent in this list uses — looking correct.
            .setTimeSignature(measureIndex: 3, numerator: 2, denominator: 2, symbol: .cutCommon),
            .removeTimeSignature(measureIndex: 4),
            // Appended for M4 rehearsal marks — indices 23…24. The mark's text is deliberately non-ASCII: it is
            // the only free-form string an intent carries, and a UTF-8 regression that truncated to the character
            // count (or dropped a continuation byte) would still round-trip an ASCII mark looking correct.
            .setRehearsalMark(measureIndex: 3, text: "1サビ"),
            .removeRehearsalMark(measureIndex: 4),
            // Appended for M6 drum note entry — indices 25…27. The three field values of `.createVoice` are
            // distinct so a field written into the wrong tag cannot survive looking right, the same reason
            // `.setTimeSignature`'s are. `.setNoteHead` is here twice: the present flag is the only thing telling
            // "write this head" from "clear the override", and a regression that dropped it would still round-trip
            // the non-nil case correctly.
            .createVoice(staff: staff, measureIndex: 7, voiceIndex: 1),
            .splitRest(at: slot, tickOffset: 240),
            .setNoteHead(at: note, headType: "cross"),
            .setNoteHead(at: note, headType: nil),
            // Index 28. Three shapes, because the payload carries the only optional-within-optional this codec has:
            // a full row with a shortcut, one without, and the removal that is an add's own inverse.
            .setDrumsetEntry(
                partIndex: 1, pitch: 42,
                entry: DrumsetEntry(
                    name: "Closed Hi-Hat", head: "cross", line: -1, voiceIndex: 0, stem: 1, shortcut: "H",
                ),
            ),
            .setDrumsetEntry(
                partIndex: 0, pitch: 36,
                entry: DrumsetEntry(name: "Bass Drum 1", head: "normal", line: 6, voiceIndex: 1, stem: 2),
            ),
            .setDrumsetEntry(partIndex: 0, pitch: 36, entry: nil),
            // Index 29. Four shapes, because each name carries its own present flag and a cleared name is not an
            // empty one: dropping either flag would still round-trip the both-present case correctly.
            .setPartNames(at: 1, longName: "なおき", shortName: "な"),
            .setPartNames(at: 1, longName: "なおき", shortName: nil),
            .setPartNames(at: 1, longName: nil, shortName: "な"),
            .setPartNames(at: 1, longName: nil, shortName: nil),
            // An empty name is a name the score declares, and must not come back as a cleared one.
            .setPartNames(at: 1, longName: "", shortName: ""),
            // Appended for the edit-command parity project (spec 2026-09-02), group 1 — indices 30…34.
            .setLayoutBreak(at: MeasureRef(measureIndex: 3), kind: .page, enabled: true),
            .setBarLine(at: MeasureRef(measureIndex: 3), style: .doubleHeavy),
            .setRepeatBarLines(at: MeasureRef(measureIndex: 3), startRepeat: true, endRepeatCount: 3),
            .setRepeatBarLines(at: MeasureRef(measureIndex: 3), startRepeat: false, endRepeatCount: nil),
            .setMeasureRepeat(at: MeasureRef(measureIndex: 3), staff: staff, numMeasures: 2),
            .setMeasureRepeat(at: MeasureRef(measureIndex: 3), staff: staff, numMeasures: nil),
            .moveToVoice(at: slot, to: VoiceRef(staff: staff, measureIndex: 3, voiceIndex: 1)),
            // Appended for the edit-command parity project (spec 2026-09-02), group 2 — indices 35…40. Both flag
            // values of `transposeRange`, a negative interval, both accidental shapes and a fraction duration, so
            // a dropped flag, a lost sign or a mis-tagged nested range cannot survive looking right.
            .transposeRange(over: range, semitones: -3, respellInKey: true),
            .transposeRange(over: range, semitones: 12, respellInKey: false),
            .addIntervalToSelection(over: range, steps: -8),
            .deleteRange(over: range),
            .setAccidentalsInRange(over: range, accidental: .flat),
            .setAccidentalsInRange(over: range, accidental: nil),
            .setDurationInRange(over: range, duration: .fraction(Fraction(numerator: 3, denominator: 8))),
            .respellRange(over: range, mode: .preferFlats),
        ]
        for intent in intents {
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }

    /// The discriminator order is frozen, and nothing else in this repo can catch a break: a case that moves encodes
    /// fine, decodes fine, and applies the WRONG edit to the mirror session on the far side of the relay. There is no
    /// build error to lean on, because both sides compile against the same enum — the break only appears when an
    /// older `.so` meets newer bytes, which is precisely the case the version stamp exists to refuse and this test
    /// exists to prevent needing.
    ///
    /// Reads the case index directly out of the frame rather than trusting a round trip. `EditIntentWire`'s top-level
    /// bytes are `varint(payloadLength)` then `varint(caseIndex)`, and every index so far is below 128, so both are
    /// single bytes and the index is `bytes[1]`. The two anchors either side of the new case are asserted too: if the
    /// framing assumption above ever stops holding, all three fail together rather than one silently drifting.
    @Test func `the wire discriminators stay where they were`() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let rest = RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        let slot = VoiceElementID(rest)
        #expect(EditIntentCodec.encode(.inputNote(at: rest, pitch: 60, tpc: 14, duration: nil))[1] == 0)
        #expect(EditIntentCodec.encode(.removeTuplet(at: slot))[1] == 11)
        #expect(EditIntentCodec.encode(.writeNote(at: slot, pitch: 60, tpc: 14, duration: nil))[1] == 12)
        #expect(EditIntentCodec.encode(.writeRest(at: slot, duration: .half))[1] == 13)
        // `.writeRest` and `.setRestDuration` encode the SAME payload, so the discriminator is the only thing
        // telling them apart on the wire — and confusing them would silently turn "make this slot a rest of this
        // length" into "re-time the rest already here", which over a note does nothing at all.
        #expect(EditIntentCodec.encode(.setRestDuration(at: slot, duration: .half))[1] == 1)
        // Appended for M1 solo scratch creation.
        #expect(EditIntentCodec.encode(.insertMeasure(at: 0))[1] == 14)
        #expect(EditIntentCodec.encode(.deleteMeasure(at: 0))[1] == 15)
        // Appended for M2 ensemble creation. `addPart` is the first case whose payload is variable-length enough
        // that the frame's own length prefix could exceed one byte — a plan with long names would push it past
        // 127 — so the index is read from a deliberately small plan, keeping the `bytes[1]` framing assumption
        // this whole test rests on true.
        #expect(EditIntentCodec.encode(
            .addPart(plan: .init(instrumentID: "x", staves: [.init(clefType: "G")]), at: 0),
        )[1] == 16)
        #expect(EditIntentCodec.encode(.removePart(at: 0))[1] == 17)
        #expect(EditIntentCodec.encode(.movePart(from: 0, to: 1))[1] == 18)
        // Appended for M3 signature changes. `.removeKeySignature`'s payload is byte-identical to
        // `.insertMeasure`'s, so — exactly as with `.writeRest` above — the discriminator is the only thing
        // standing between "drop this key change" and "insert a bar here".
        #expect(EditIntentCodec.encode(.setKeySignature(measureIndex: 0, concertKey: 0))[1] == 19)
        #expect(EditIntentCodec.encode(.removeKeySignature(measureIndex: 0))[1] == 20)
        // `.removeTimeSignature`'s payload is byte-identical to `.removeKeySignature`'s, and confusing the two
        // would drop the wrong declaration and re-bar (or re-spell) a span nobody asked about.
        #expect(EditIntentCodec.encode(
            .setTimeSignature(measureIndex: 0, numerator: 3, denominator: 4),
        )[1] == 21)
        #expect(EditIntentCodec.encode(.removeTimeSignature(measureIndex: 0))[1] == 22)
        // Appended for M4 rehearsal marks. `.removeRehearsalMark`'s payload is byte-identical to
        // `.removeTimeSignature`'s in turn, so the discriminator is again the only thing standing between dropping
        // a mark and re-barring the span after it. `setRehearsalMark` is read from a one-character mark: it is the
        // second variable-length payload in this file, and a long mark would push the frame's length prefix past
        // 127 and break the `bytes[1]` framing assumption this whole test rests on, exactly as `addPart` above.
        #expect(EditIntentCodec.encode(.setRehearsalMark(measureIndex: 0, text: "A"))[1] == 23)
        #expect(EditIntentCodec.encode(.removeRehearsalMark(measureIndex: 0))[1] == 24)
        // Appended for M6 drum note entry. `.setNoteHead` is read with its head cleared, which keeps its payload
        // short for the same `bytes[1]` framing reason `setRehearsalMark` above uses a one-character mark — a long
        // head name would push the frame's length prefix past 127.
        #expect(EditIntentCodec.encode(
            .createVoice(staff: staff, measureIndex: 0, voiceIndex: 1),
        )[1] == 25)
        #expect(EditIntentCodec.encode(.splitRest(at: slot, tickOffset: 240))[1] == 26)
        #expect(EditIntentCodec.encode(
            .setNoteHead(
                at: NoteID(
                    staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
                ),
                headType: nil,
            ),
        )[1] == 27)
        // Read with the entry removed, which keeps the payload short for the same `bytes[1]` framing reason.
        #expect(EditIntentCodec.encode(.setDrumsetEntry(partIndex: 0, pitch: 42, entry: nil))[1] == 28)
        // Appended for part renaming.
        #expect(EditIntentCodec.encode(.setPartNames(at: 0, longName: nil, shortName: nil))[1] == 29)
        // Appended for the edit-command parity project (spec 2026-09-02), group 1.
        #expect(EditIntentCodec.encode(
            .setLayoutBreak(at: MeasureRef(measureIndex: 0), kind: .line, enabled: true),
        )[1] == 30)
        #expect(EditIntentCodec.encode(.setBarLine(at: MeasureRef(measureIndex: 0), style: .end))[1] == 31)
        #expect(EditIntentCodec.encode(
            .setRepeatBarLines(at: MeasureRef(measureIndex: 0), startRepeat: false, endRepeatCount: nil),
        )[1] == 32)
        #expect(EditIntentCodec.encode(
            .setMeasureRepeat(at: MeasureRef(measureIndex: 0), staff: staff, numMeasures: nil),
        )[1] == 33)
        #expect(EditIntentCodec.encode(
            .moveToVoice(at: slot, to: VoiceRef(staff: staff, measureIndex: 0, voiceIndex: 1)),
        )[1] == 34)
        // Appended for the edit-command parity project (spec 2026-09-02), group 2. A range is two nested
        // `VoiceElementIDWire`s — about 30 bytes at these small indices — so the frame's length prefix stays one
        // byte and the `bytes[1]` framing assumption holds.
        let range = VoiceElementRange(start: slot, end: slot)
        #expect(EditIntentCodec.encode(.transposeRange(over: range, semitones: 1, respellInKey: false))[1] == 35)
        #expect(EditIntentCodec.encode(.addIntervalToSelection(over: range, steps: 3))[1] == 36)
        #expect(EditIntentCodec.encode(.deleteRange(over: range))[1] == 37)
        #expect(EditIntentCodec.encode(.setAccidentalsInRange(over: range, accidental: nil))[1] == 38)
        #expect(EditIntentCodec.encode(.setDurationInRange(over: range, duration: .half))[1] == 39)
        #expect(EditIntentCodec.encode(.respellRange(over: range, mode: .simplest))[1] == 40)
    }

    /// A `PartPlan` is the one intent payload that is not scalars-only, so its round trip has to be checked field
    /// by field rather than trusting `EditIntent`'s synthesized `==` alone — a plan whose `staves` array or
    /// present-flagged optional names decoded wrong would still compare equal to itself if the flags were dropped
    /// on BOTH sides of the trip.
    @Test func `a part plan's every field survives the wire`() throws {
        let plan = BlankScoreTemplate.PartPlan(
            instrumentID: "clarinet-bb", longName: "Clarinet in B♭", shortName: "Cl.",
            staves: [.init(clefType: "G"), .init(clefType: "PERC", isPercussion: true)],
            transposeDiatonic: -1, transposeChromatic: -2, gmProgram: 71, isDrums: true,
        )
        let bytes = EditIntentCodec.encode(.addPart(plan: plan, at: 3))
        guard case let .addPart(decoded, index) = try EditIntentCodec.decode(bytes) else {
            Issue.record("expected .addPart"); return
        }
        #expect(index == 3)
        #expect(decoded.instrumentID == "clarinet-bb")
        #expect(decoded.longName == "Clarinet in B♭")
        #expect(decoded.shortName == "Cl.")
        #expect(decoded.staves.count == 2)
        #expect(decoded.staves[0].clefType == "G")
        #expect(decoded.staves[0].isPercussion == false)
        #expect(decoded.staves[1].clefType == "PERC")
        #expect(decoded.staves[1].isPercussion)
        #expect(decoded.transposeDiatonic == -1)
        #expect(decoded.transposeChromatic == -2)
        #expect(decoded.gmProgram == 71)
        #expect(decoded.isDrums)
    }

    /// An absent name has to come back absent, not as `""` — the two are different instruments as far as the mscx
    /// encoder is concerned (`<longName>` written empty versus omitted).
    @Test func `an absent part-plan name decodes as nil, not empty string`() throws {
        let plan = BlankScoreTemplate.PartPlan(instrumentID: "x", staves: [.init(clefType: "G")])
        guard case let .addPart(decoded, _) = try EditIntentCodec
            .decode(EditIntentCodec.encode(.addPart(plan: plan, at: 0)))
        else {
            Issue.record("expected .addPart"); return
        }
        #expect(decoded.longName == nil)
        #expect(decoded.shortName == nil)
    }

    /// An accidental spelling this build does not know must fail the decode, not decode as "no accidental" —
    /// a silent nil would put a different glyph on the mirror than the authoritative score carries.
    ///
    /// Every `Accidental` raw value is pure ASCII, so `^= 0xFF` would always land in `0x80...0xFF` — an orphan
    /// UTF-8 continuation byte, never valid UTF-8 — and the wire layer's own `invalidUTF8` would fire before
    /// `AccidentalWire.decoded()` ever runs, which would leave the accidental-refusal path itself unexercised.
    /// `^= 0x01` instead flips one bit of one ASCII letter, landing on another printable ASCII letter (this byte
    /// is `"accidentalSharp"`'s second-to-last `'r'`, which becomes `'s'`, so the encoded string becomes
    /// `"accidentalShasp"` — verified by printing the mutated bytes while writing this test) — still valid UTF-8,
    /// but a spelling `Accidental(rawValue:)` does not recognize, so the throw actually comes from
    /// `AccidentalWire.decoded()`'s own guard, not the wire decoder's UTF-8 check. Asserting the specific error
    /// (not just "throws") is what keeps that distinction visible: a future regression back to
    /// `invalidUTF8`-only coverage would go silently green under `(any Error).self`.
    @Test func `an unknown accidental spelling is refused`() throws {
        var bytes = EditIntentCodec.encode(.setAccidental(
            at: NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
                noteIndexInChord: 0,
            ),
            accidental: .sharp,
        ))
        // Corrupt one ASCII byte of the accidental's raw-value string payload: the last byte before the frame's
        // final byte (the length-delimited `raw` field is the last thing this wire struct encodes).
        let index = try #require(bytes.indices.last.map { max(bytes.startIndex, $0 - 1) })
        bytes[index] ^= 0x01
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(0)) { try EditIntentCodec.decode(bytes) }
    }

    /// A `kind` outside `LayoutBreakKind`'s cases (1…3) must not decode as one of them — a newer writer's break
    /// kind must not silently become a different break on an older reader. `0` is deliberately unassigned by
    /// `LayoutBreakKind` for exactly this hand-mutated test.
    @Test func `a layout break kind outside the known cases is refused`() {
        var wire = SetLayoutBreakIntentWire(measure: MeasureRef(measureIndex: 0), kind: .line, enabled: true)
        wire.kind = 0
        let bytes = EditIntentWire.setLayoutBreak(wire).encodeToData()
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(bytes)
        }
    }

    /// A barline style spelling this build does not know must fail the decode, not decode as `.normal` — the same
    /// forward-compatibility rule `AccidentalWire.decoded()` enforces on its own raw-string payload.
    @Test func `an unknown barline style spelling is refused`() {
        var wire = SetBarLineIntentWire(measure: MeasureRef(measureIndex: 0), style: .end)
        wire.style = "zigzag"
        let bytes = EditIntentWire.setBarLine(wire).encodeToData()
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(bytes)
        }
    }
}
