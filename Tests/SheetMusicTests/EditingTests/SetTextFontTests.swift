@testable import SheetMusicCore
import Testing

@Suite("Set text font")
struct SetTextFontTests {
    private static let first = VoiceElementID(
        staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )
    private static let anchor = first.withElementIndex(2)
    private static let ids: [ScoreTextID] = [
        .lyric(anchor: anchor, verse: 0),
        .staffText(anchor: anchor, style: .staffText),
        .staffText(anchor: anchor, style: .systemText),
        .rehearsalMark(measureIndex: 0), .harmony(anchor: anchor),
    ]

    private static func populated() throws -> Score {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        _ = try SetLyric(at: first, verse: 0, text: "la").apply(to: &score)
        _ = try SetStaffText(anchor: first, text: "pizz.", isSystemText: false).apply(to: &score)
        _ = try SetStaffText(anchor: first, text: "Swing", isSystemText: true).apply(to: &score)
        _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
        _ = try SetChordSymbol(at: first, name: "Am7").apply(to: &score)
        return score
    }

    @Test("each of five fields moves the hash on every carrier, including explicit empty and zero values")
    func everyOccupant() throws {
        let patches: [SetTextFont.Patch] = [
            .init(face: .set("Edwin")), .init(face: .set("")),
            .init(size: .set(12)), .init(size: .set(0)),
            .init(style: .set([.bold, .italic, .underline, .strike])), .init(style: .set([])),
            .init(frameType: .set(.circle)), .init(frameType: .set(TextFrameType.none)),
            .init(framePadding: .set(2)), .init(framePadding: .set(0)),
        ]
        for id in Self.ids {
            for patch in patches {
                var score = try Self.populated()
                let before = score
                let originalHash = score.stableFingerprint
                let undo = try SetTextFont(id, patch: patch).apply(to: &score)
                #expect(score.stableFingerprint != originalHash)
                #expect(SetTextFont.current(id, in: score) == patch.applying(to: TextProperties()))
                for other in Self.ids where other != id {
                    #expect(SetTextFont.current(other, in: score) == SetTextFont.current(other, in: before))
                }
                let changed = score
                let redo = try undo.apply(to: &score)
                #expect(score == before)
                #expect(score.stableFingerprint == originalHash)
                _ = try redo.apply(to: &score)
                #expect(score == changed)
            }
        }
    }

    @Test("clear differs from leave alone and planning drops only real restatements")
    func threeStates() throws {
        for id in Self.ids {
            var score = try Self.populated()
            let all = SetTextFont.Patch(
                face: .set("Edwin"), size: .set(12), style: .set(.bold),
                frameType: .set(.rectangle), framePadding: .set(2),
            )
            _ = try SetTextFont(id, patch: all).apply(to: &score)
            #expect(try ScoreEditSession.command(for: .setTextFont(text: id, patch: all), in: score, depth: 0) == nil)
            #expect(try ScoreEditSession.command(
                for: .setTextFont(text: id, patch: .init()),
                in: score,
                depth: 0,
            ) == nil)
            let before = score
            let clear = SetTextFont.Patch(size: .clear)
            let planned = try ScoreEditSession.command(
                for: .setTextFont(text: id, patch: clear), in: score, depth: 0,
            )
            let command = try #require(planned)
            let undo = try command.apply(to: &score)
            #expect(SetTextFont.current(id, in: score) == TextProperties(
                face: "Edwin", style: .bold, frameType: .rectangle, framePadding: 2,
            ))
            #expect(score.stableFingerprint != before.stableFingerprint)
            _ = try undo.apply(to: &score)
            #expect(score == before)
        }
    }

    @Test("an empty patch on a missing carrier still refuses and never edits its anchor")
    func missingTargets() throws {
        for id in Self.ids {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            let before = score
            let planned = try ScoreEditSession.command(
                for: .setTextFont(text: id, patch: .init()), in: score, depth: 0,
            )
            let command = try #require(planned)
            #expect(throws: SheetMusicError.self) { try command.apply(to: &score) }
            #expect(score == before)
        }
    }

    @Test("planning and fingerprint agree on signed zero and identical NaN payloads")
    func floatingPointOccupants() throws {
        for id in Self.ids {
            var score = try Self.populated()
            _ = try SetTextFont(id, patch: .init(size: .set(0), framePadding: .set(0))).apply(to: &score)
            let before = score
            let negativeZero = SetTextFont.Patch(size: .set(-0.0), framePadding: .set(-0.0))
            let planned = try ScoreEditSession.command(
                for: .setTextFont(text: id, patch: negativeZero), in: score, depth: 0,
            )
            let command = try #require(planned)
            let inverse = try command.apply(to: &score)
            #expect(score.stableFingerprint != before.stableFingerprint)
            _ = try inverse.apply(to: &score)
            #expect(score.stableFingerprint == before.stableFingerprint)
            let nan = SetTextFont.Patch(size: .set(Double(bitPattern: 0x7FF8_0000_0000_0001)))
            _ = try SetTextFont(id, patch: nan).apply(to: &score)
            #expect(try ScoreEditSession.command(
                for: .setTextFont(text: id, patch: nan),
                in: score,
                depth: 0,
            ) == nil)
        }
    }

    @Test("all nil properties emit zero bytes in every tag block")
    func nilIsByteFree() {
        for tag in [85, 90, 95, 100] {
            var hash = FNV1a()
            hash.combine("prefix")
            let before = hash.value
            hash.combineOccupied(TextProperties(), firstTag: tag)
            #expect(hash.value == before)
        }
    }

    @Test("canonically equivalent face names remain distinct authored UTF-8 writes")
    func faceBytesArePreserved() throws {
        let id = ScoreTextID.rehearsalMark(measureIndex: 0)
        var score = try Self.populated()
        _ = try SetTextFont(id, patch: .init(face: .set("\u{E9}"))).apply(to: &score)
        let before = score.stableFingerprint
        let planned = try ScoreEditSession.command(
            for: .setTextFont(text: id, patch: .init(face: .set("e\u{301}"))), in: score, depth: 0,
        )
        let command = try #require(planned)
        let inverse = try command.apply(to: &score)
        #expect(score.stableFingerprint != before)
        _ = try inverse.apply(to: &score)
        #expect(score.stableFingerprint == before)
    }
}
