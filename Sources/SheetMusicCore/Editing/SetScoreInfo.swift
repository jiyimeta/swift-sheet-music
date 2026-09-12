import SheetMusicFoundation

/// Writes a score's credit fields — title, subtitle, composer, arranger, lyricist, copyright — into both places a
/// score keeps them: the `<metaTag>` dictionary and the engraved title frame.
///
/// See `ScoreInfoWrite` for why one write reaches two places. What this command adds on top is the frame itself: a
/// score created from scratch has no `<VBox>` until something needs engraving, so writing a title into one MAKES
/// the frame, which is what MuseScore's own "Add > Text > Title" does to an empty score. The height it is born with
/// is `Score.blank`'s 10sp, so a score that gets its title typed in afterwards ends up with the frame it would have
/// had if the title had been given at creation.
///
/// The inverse restores `blocks` and `metaTags` wholesale rather than replaying per-field undos. That is the
/// `SetStaffText` / `SetTempo` idiom, and it is what makes the round trip exact for the cases a field-by-field
/// inverse gets wrong: a frame this command created (undo must remove it, not blank its text), a frame whose
/// `preservedMarkup` or per-text offsets came from an imported file, and a `<metaTag>` that was absent rather than
/// empty.
public struct SetScoreInfo: EditCommand {
    public let writes: [ScoreInfoWrite]
    /// Pre-image for the restore path. `nil` on a forward command; set on the inverse `apply` returns.
    let restoredBlocks: [PositionedScoreBlock]?
    let restoredMetaTags: [String: String]?

    public init(writes: [ScoreInfoWrite]) {
        self.writes = writes
        restoredBlocks = nil
        restoredMetaTags = nil
    }

    init(restoringBlocks blocks: [PositionedScoreBlock], metaTags: [String: String]) {
        writes = []
        restoredBlocks = blocks
        restoredMetaTags = metaTags
    }

    /// A score-level edit has no voice element to name; the head of the score is where a host would scroll to show
    /// the title block, and is the answer `AddPart` and `SetStaffDefaultClef` give for the same reason.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: Score.canonicalStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score, ids _: inout EIDAllocator) throws -> any EditCommand {
        let previousBlocks = score.blocks
        let previousMetaTags = score.metaTags
        // Decided before anything is read, for `SetStaffText`'s reason: an inverse carries its own pre-image and
        // must never refuse.
        if let restoredBlocks, let restoredMetaTags {
            score.blocks = restoredBlocks
            score.metaTags = restoredMetaTags
            return SetScoreInfo(restoringBlocks: previousBlocks, metaTags: previousMetaTags)
        }
        guard !writes.isEmpty else { throw Self.refused(.nothingToApply) }
        for write in writes {
            let value = write.normalizedText
            score.metaTags[write.field.metaTagKey] = value
            if let style = write.field.frameTextStyle {
                Self.write(value, as: style, into: &score)
            }
        }
        return SetScoreInfo(restoringBlocks: previousBlocks, metaTags: previousMetaTags)
    }

    /// Put `value` in the title frame under `style`, or take that text out when `value` is `nil`.
    ///
    /// A rename mutates the existing `FrameText` in place so its offset, font size and alignment survive — the same
    /// promise `SetStaffText` makes about a mark's own properties. Order follows `FrameText.Style`'s declaration
    /// (title, subtitle, composer, lyricist), so a text this command adds lands where a reader expects it rather
    /// than at the end of whatever the file happened to carry.
    private static func write(_ value: String?, as style: FrameText.Style, into score: inout Score) {
        guard var frame = score.titleFrame else {
            // Nothing to engrave and no frame to engrave it in: a cleared field on a score without a title block
            // must not conjure one.
            guard let value else { return }
            // 10sp is `Score.blank`'s own VBox height, so a score titled after the fact ends up with the frame it
            // would have had if the title had been given at creation.
            score.titleFrame = ScoreFrame(heightSp: 10, texts: [FrameText(style: style, text: value)])
            return
        }
        if let index = frame.texts.firstIndex(where: { $0.style == style }) {
            if let value {
                frame.texts[index].text = value
            } else {
                frame.texts.remove(at: index)
            }
        } else if let value {
            frame.texts.insert(
                FrameText(style: style, text: value), at: insertionIndex(for: style, in: frame.texts),
            )
        }
        score.titleFrame = frame
    }

    /// Where a newly added text of `style` belongs among the frame's existing ones: before the first text whose
    /// role is declared after it. Texts the model does not rank (`.other`, carried in from a file) sort last and
    /// are never stepped over.
    private static func insertionIndex(for style: FrameText.Style, in texts: [FrameText]) -> Int {
        let order = FrameText.Style.engravingOrder
        guard let rank = order.firstIndex(of: style) else { return texts.count }
        return texts.firstIndex { text in
            guard let other = order.firstIndex(of: text.style) else { return true }
            return other > rank
        } ?? texts.count
    }

    /// What this score already says for `field`, as `ScoreInfoWrite` would normalize it. The engraved text wins
    /// where the two disagree — it is what the user can SEE, so it is what "already says" has to mean for a
    /// restatement check that is deciding whether the page will change.
    public static func current(_ field: ScoreInfoWrite.Field, in score: Score) -> String? {
        if let style = field.frameTextStyle,
           let text = score.titleFrame?.texts.first(where: { $0.style == style })?.text,
           !text.trimmingWhitespaceAndNewlines().isEmpty
        {
            return text.trimmingWhitespaceAndNewlines()
        }
        guard let tag = score.metaTags[field.metaTagKey]?.trimmingWhitespaceAndNewlines(), !tag.isEmpty else {
            return nil
        }
        return tag
    }

    /// Whether every write restates what the score already says — the `.nothingToApply` case the session's planner
    /// turns into `nil` rather than into a self-restoring undo entry.
    public static func isRestatement(_ writes: [ScoreInfoWrite], in score: Score) -> Bool {
        writes.allSatisfy { write in
            // A field with an engraved style is a restatement only when BOTH places already agree: a metaTag that
            // matches while the title block is empty is exactly the state this command exists to repair, and
            // planning it to `nil` would leave the page blank forever.
            guard current(write.field, in: score) == write.normalizedText else { return false }
            guard let style = write.field.frameTextStyle else { return true }
            let engraved = score.titleFrame?.texts
                .first { $0.style == style }?.text.trimmingWhitespaceAndNewlines()
            let stored = score.metaTags[write.field.metaTagKey]?.trimmingWhitespaceAndNewlines()
            return (engraved?.isEmpty == false ? engraved : nil) == (stored?.isEmpty == false ? stored : nil)
        }
    }
}

extension FrameText.Style {
    /// The roles a title block engraves, top to bottom — the order `Score.blank` writes them in and the order
    /// MuseScore's own styles place them. `.other` is deliberately absent: it names a text the model does not rank.
    static let engravingOrder: [FrameText.Style] = [.title, .subtitle, .composer, .lyricist]
}
