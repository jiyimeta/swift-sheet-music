import SheetMusicFoundation

/// Strict address boundary for editors displaying a score with hidden staves removed.
/// Unlike playback cursor translation, an unresolved staff address cannot become a beat or pass through.
/// Commands retain responsibility for validating the target's element kind and contents.
public struct ScoreEditingAddressMap: Sendable {
    public let score: Score
    public let hiddenStaves: Set<StaffAddress>
    /// Optional full-score text preview. Existing voice-slot identities map insertion/removal shifts
    /// within the same voice; preview-only slots have no committed edit target.
    public let previewScore: Score?

    public init(score: Score, hiddenStaves: Set<StaffAddress>, previewScore: Score? = nil) {
        self.score = score
        self.hiddenStaves = hiddenStaves
        self.previewScore = previewScore
    }

    /// Full-score staff addresses in displayed order. Range edits and paste destinations must walk
    /// this list, since walking between full-score endpoints also visits hidden middle staves.
    public var visibleStaffAddresses: [StaffAddress] {
        score.allStaves.map(\.address).filter { !hiddenStaves.contains($0) }
    }

    public func fullItem(forDisplayed item: ScoreItemID) -> ScoreItemID? {
        if item.isAddressedByBar { return item }
        guard let staff = score.unfilterStaffAddress(item.staff, hidingStaves: hiddenStaves),
              score[staff] != nil
        else { return nil }
        if case let .element(.tie(_, end)) = item {
            guard let endStaff = score.unfilterStaffAddress(end.staff, hidingStaves: hiddenStaves),
                  score[endStaff] != nil
            else { return nil }
        }
        guard case let .item(full) = score.engineCursorForFilteredTap(.item(item), hiddenStaves: hiddenStaves)
        else { return nil }
        guard let previewScore else { return full }
        return full.mappingVoiceElements { position in
            Self.position(position, from: previewScore, to: score)
        }
    }

    public func displayedItem(forFull originalItem: ScoreItemID) -> ScoreItemID? {
        if originalItem.isAddressedByBar { return originalItem }
        let item: ScoreItemID
        if let previewScore {
            guard let mapped = originalItem.mappingVoiceElements({ position in
                Self.position(position, from: score, to: previewScore)
            }) else { return nil }
            item = mapped
        } else {
            item = originalItem
        }
        guard score[item.staff] != nil,
              score.filterStaffAddress(item.staff, hidingStaves: hiddenStaves) != nil
        else { return nil }
        if case let .element(.tie(_, end)) = item {
            guard score[end.staff] != nil,
                  score.filterStaffAddress(end.staff, hidingStaves: hiddenStaves) != nil
            else { return nil }
        }
        guard case let .item(displayed) = score.translateCursorForHiddenStaves(
            .item(item), hiddenStaves: hiddenStaves,
        ) else { return nil }
        return displayed
    }

    private static func position(
        _ position: VoiceElementID, from source: Score, to destination: Score,
    ) -> VoiceElementID? {
        guard let eid = source.eid(at: position),
              let staff = destination[position.staff],
              staff.measures.indices.contains(position.measureIndex),
              staff.measures[position.measureIndex].voices.indices.contains(position.voiceIndex),
              let index = staff.measures[position.measureIndex].voices[position.voiceIndex].elements.index(of: eid)
        else { return nil }
        return VoiceElementID(
            staff: position.staff, measureIndex: position.measureIndex,
            voiceIndex: position.voiceIndex, elementIndex: index,
        )
    }
}

extension ScoreItemID {
    fileprivate var isAddressedByBar: Bool {
        if case .text(.rehearsalMark) = self { return true }
        return elementID?.measureIndexIfAddressedByBar != nil
    }
}
