import SheetMusicCore

/// A displayed selection and the exact address space in which its positions were written.
/// Hosts use the same transition for preview updates and layout-mode changes. Explicit full-score
/// synchronization updates both values, so a later render cannot reinterpret new positions as old ones.
public struct ScoreEditingSelection: Sendable {
    public private(set) var selection: ScoreSelection = .none
    public private(set) var addresses: ScoreEditingAddressMap?

    public init() {}

    public mutating func selectDisplayed(_ selection: ScoreSelection, in addresses: ScoreEditingAddressMap?) {
        self.selection = addresses == nil ? .none : selection
        self.addresses = addresses
    }

    public mutating func selectFull(_ item: ScoreItemID, in addresses: ScoreEditingAddressMap?) {
        let displayed = addresses?.displayedItem(forFull: item).map { ScoreSelection.single($0) } ?? .none
        selectDisplayed(displayed, in: addresses)
    }

    /// Follows existing voice-slot EIDs through the previous display, the new committed score, and
    /// the new display. A removed slot clears the selection; preview-only slots never acquire a target.
    public mutating func transition(to next: ScoreEditingAddressMap) {
        guard let previous = addresses else {
            selectDisplayed(.none, in: next)
            return
        }
        let committed = ScoreEditingAddressMap(
            score: next.score, hiddenStaves: previous.hiddenStaves,
            previewScore: previous.previewScore ?? previous.score,
        )
        let translated = Self.translating(selection) { item in
            guard let full = committed.fullItem(forDisplayed: item) else { return nil }
            return next.displayedItem(forFull: full)
        }
        selectDisplayed(translated, in: next)
    }

    private static func translating(
        _ selection: ScoreSelection, with transform: (ScoreItemID) -> ScoreItemID?,
    ) -> ScoreSelection {
        switch selection {
        case .none: return .none
        case let .single(item): return transform(item).map { .single($0) } ?? .none
        case let .range(anchor, target):
            guard let anchor = transform(anchor), let target = transform(target) else { return .none }
            return .range(anchor: anchor, target: target)
        case let .multi(items):
            let mapped = items.compactMap(transform)
            return mapped.count == items.count ? .multi(Set(mapped)) : .none
        }
    }
}
