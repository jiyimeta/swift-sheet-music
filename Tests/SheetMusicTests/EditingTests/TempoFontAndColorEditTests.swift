@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// A tempo marking's color (`SetElementColor.Target.tempo`) and font (`SetTempoFont`, intent 89), driven the
/// way a host drives them: through `ScoreEditSession`, then read back from the model, from the laid-out
/// element the renderers draw, and from the undo stack.
@Suite("Tempo color and font edits")
struct TempoFontAndColorEditTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let anchor = VoiceElementID(
        staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )
    /// A chord on a different beat of the same bar, where no tempo sits.
    private static let elsewhere = VoiceElementID(
        staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
    )
    private static let red = ScoreColor(red: 200, green: 10, blue: 20)

    private static func scoreWithTempo() throws -> Score {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        _ = try SetTempo(anchor: anchor, marking: .init(beatsPerSecond: 2)).apply(to: &score)
        return score
    }

    /// The payload of the one tempo mark layout emits for `score`.
    private static func laidOutTempo(
        _ score: Score,
    ) throws -> (color: ScoreColor?, properties: TextProperties) {
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 800)
        let payloads = document.systems.flatMap(\.measures).flatMap(\.elements).compactMap { element in
            if case let .textMark(.tempo(_, color, properties), _, _) = element { (color, properties) } else { nil }
        }
        try #require(payloads.count == 1)
        return payloads[0]
    }

    @Test("a tempo color lands on the model and on the laid-out mark, and undo restores it")
    func colorThroughTheSession() throws {
        let before = try Self.scoreWithTempo()
        let session = ScoreEditSession(score: before)
        let intent = EditIntent.setElementColor(target: .tempo(anchor: Self.anchor), color: Self.red)
        #expect(session.apply(intent))
        let after = session.score
        #expect(SetElementColor.currentProperties(for: .tempo(anchor: Self.anchor), in: after)?.color == Self.red)
        #expect(try Self.laidOutTempo(after).color == Self.red)
        #expect(after.stableFingerprint != before.stableFingerprint)
        #expect(session.lastAffectedLocation == Self.anchor)

        #expect(!session.apply(intent))
        #expect(session.lastRefusal?.reason == .nothingToApply)

        #expect(session.undo())
        #expect(session.score == before)
        #expect(try Self.laidOutTempo(session.score).color == nil)
        #expect(session.redo())
        #expect(session.score == after)
    }

    @Test("a tempo font patch lands on the model and on the laid-out mark, and undo restores it")
    func fontThroughTheSession() throws {
        let before = try Self.scoreWithTempo()
        let session = ScoreEditSession(score: before)
        let patch = SetTextFont.Patch(size: .set(20), style: .set([.italic]), framePadding: .set(1))
        let intent = EditIntent.setTempoFont(anchor: Self.anchor, patch: patch)
        #expect(session.apply(intent))
        let after = session.score
        #expect(SetTempoFont.current(at: Self.anchor, in: after) == TextProperties(
            size: 20, style: [.italic], framePadding: 1,
        ))
        // Layout carries the font fields only: the frame fields are nothing a tempo draws.
        #expect(try Self.laidOutTempo(after).properties == TextProperties(size: 20, style: [.italic]))
        #expect(after.stableFingerprint != before.stableFingerprint)

        #expect(!session.apply(intent))
        #expect(session.lastRefusal?.reason == .nothingToApply)

        #expect(session.undo())
        #expect(session.score == before)
        #expect(try Self.laidOutTempo(session.score).properties == TextProperties())
        #expect(session.redo())
        #expect(session.score == after)
    }

    @Test("rewriting the marking keeps the color and font a host set")
    func markingEditKeepsColorAndFont() throws {
        var score = try Self.scoreWithTempo()
        _ = try SetElementColor(.tempo(anchor: Self.anchor), color: Self.red).apply(to: &score)
        _ = try SetTempoFont(anchor: Self.anchor, patch: .init(face: .set("Edwin"))).apply(to: &score)
        _ = try SetTempo(anchor: Self.anchor, marking: .init(beatsPerSecond: 3)).apply(to: &score)
        let tempo = try #require(SetTempo.tempo(at: Self.anchor, in: score))
        #expect(tempo.beatsPerSecond == 3)
        #expect(tempo.elementProperties.color == Self.red)
        #expect(tempo.properties.face == "Edwin")
    }

    @Test("a beat without a tempo is refused as targetNotFound for both writes")
    func missingTempoIsRefused() throws {
        let session = try ScoreEditSession(score: Self.scoreWithTempo())
        #expect(!session.apply(.setElementColor(target: .tempo(anchor: Self.elsewhere), color: Self.red)))
        #expect(session.lastRefusal?.reason == .targetNotFound(Self.elsewhere))
        #expect(!session.apply(.setElementColor(target: .tempo(anchor: Self.elsewhere), color: nil)))
        #expect(session.lastRefusal?.reason == .targetNotFound(Self.elsewhere))
        #expect(!session.apply(.setTempoFont(anchor: Self.elsewhere, patch: .init(size: .set(12)))))
        #expect(session.lastRefusal?.reason == .targetNotFound(Self.elsewhere))
        #expect(!session.canUndo)
    }
}
