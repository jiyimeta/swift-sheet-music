@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips and the discriminator pin for the text-visibility payload (intent 75, macOS score-text-entry, spec
/// 2026-09-07). Its own file, like `EditIntentCodecLyricsTests` next to it, because `EditIntentCodecTests.swift`
/// is past SwiftLint's 400-line budget already.
///
/// This is the first intent whose address is a `ScoreTextID`, so the round trips below are also the first
/// coverage of `ScoreTextIDWire` inside an INTENT rather than inside a selection — the two paths share the
/// projection deliberately, and a divergence would show up here.
@Suite("EditIntentCodec — text visibility payload")
struct EditIntentCodecTextVisibilityTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)

    /// Every `ScoreTextID` kind, in both directions — including the two `staffText` styles, which cross as one
    /// bool and are the pair a collapsed projection would silently merge.
    private static let cases: [EditIntent] = [
        .setTextVisible(text: .lyric(anchor: slot, verse: 0), visible: false),
        .setTextVisible(text: .lyric(anchor: slot, verse: 3), visible: true),
        .setTextVisible(text: .staffText(anchor: slot, style: .staffText), visible: false),
        .setTextVisible(text: .staffText(anchor: slot, style: .systemText), visible: false),
        .setTextVisible(text: .harmony(anchor: slot), visible: false),
        .setTextVisible(text: .harmony(anchor: slot), visible: true),
        .setTextVisible(text: .rehearsalMark(measureIndex: 0), visible: false),
        .setTextVisible(text: .rehearsalMark(measureIndex: 17), visible: true),
    ]

    @Test("every text-visibility intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: the payload stays under 128 bytes at
    /// these small indices, so the case index is the second byte.
    @Test func `the wire discriminator is 75`() {
        let bytes = EditIntentCodec.encode(
            .setTextVisible(text: .rehearsalMark(measureIndex: 0), visible: false),
        )
        #expect(bytes[1] == 75)
        #expect(bytes.count < 128)
    }

    /// 74 is still 74 — the pin `EditIntentCodecLyricsTests` holds, restated from this side because appending 75
    /// is exactly the change that could have disturbed it.
    @Test func `appending 75 left 74 where it was`() {
        #expect(EditIntentCodec.encode(.setLyricSyllables(writes: []))[1] == 74)
    }

    /// A non-zero `visible` byte a hand-built wire could carry reads as shown, the same rule intents 58…61 state
    /// for their own `u8` flag — so a far side that writes 2 for true is understood rather than refused.
    @Test func `any non-zero visible byte reads as shown`() throws {
        var wire = SetTextVisibleIntentWire(text: .harmony(anchor: Self.slot), visible: false)
        wire.visible = 2
        let decoded = try EditIntentCodec.decode(EditIntentWire.setTextVisible(wire).encodeToData())
        #expect(decoded == .setTextVisible(text: .harmony(anchor: Self.slot), visible: true))
    }
}
