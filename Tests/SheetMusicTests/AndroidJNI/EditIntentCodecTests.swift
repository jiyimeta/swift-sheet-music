import Foundation
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore
import Testing

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

    /// `CompositeIntentWire.members` recurses with no depth bound of its own; a malformed payload nesting far past
    /// what a real composite ever does (production nests at most 2 deep) must be refused, not overflow the stack
    /// unwinding the decode. 20 levels is nowhere near a real stack limit to *build* — this is checking the
    /// decoder's own policy limit fires well before that, not working around a crash that already happened.
    @Test("a composite nested past the depth limit throws instead of overflowing the stack")
    func deeplyNestedCompositeThrows() {
        var intent = EditIntent.delete(at: Self.slot)
        for _ in 0 ..< 20 {
            intent = .composite([intent])
        }
        let bytes = EditIntentCodec.encode(intent)
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(bytes)
        }
    }
}
