@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicRenderWindows
import Testing

/// `ScorePageOptions` is the typed twin of `LayoutOptionsWire`: its default has to be the wire's `verticalDefault`, and
/// each property has to land on its own wire field, in the encoding the bridge reads back.
///
/// Values are computed outside `#expect`, which would otherwise have to expand the closures and key paths they use.
@Suite("ScorePageOptions")
struct ScorePageOptionsTests {
    @Test("the default is the wire's vertical default, field by field")
    func defaultIsVerticalDefault() {
        expectSame(ScorePageOptions.default.wire(), LayoutOptionsWire.verticalDefault)
    }

    @Test("an all-default spacing sends no spacing at all")
    func emptySpacingIsNil() {
        let spacing = ScorePageOptions.default.wire().spacing
        #expect(spacing == nil)
    }

    @Test("the mode")
    func mode() {
        let expected: [(ScorePageOptions.Mode, UInt8)] = [(.vertical, 0), (.horizontal, 1), (.page, 2)]
        for (mode, raw) in expected {
            let sent = wire { $0.mode = mode }
            #expect(sent.layoutMode == raw, "\(mode)")
        }
    }

    @Test("the staff, the invisible elements, the lyrics and the transposition")
    func scalars() {
        let resized = wire { $0.staffSize = 20 }
        #expect(resized.staffSize == 20)
        let showingInvisible = wire { $0.showsInvisibleElements = true }
        #expect(showingInvisible.showsInvisibleElements == 1)
        let hidingLyrics = wire { $0.showsLyrics = false }
        #expect(hidingLyrics.showsLyrics == 0)
        #expect(!hidingLyrics.lyricsVisible)
        let transposed = wire { $0.transposeSemitones = -3 }
        #expect(transposed.transposeSemitones == -3)
        #expect(transposed.transposeDelta == -3)
    }

    @Test("hidden staves and clef overrides, in address order")
    func staves() {
        let first = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let second = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let hiding = wire { $0.hiddenStaves = [second, first] }
        let hiddenPairs = hiding.hiddenStaves.map { [$0.partIndex, $0.staffIndexInPart] }
        let hiddenAddresses = hiding.hiddenStaffAddresses
        #expect(hiddenPairs == [[0, 1], [1, 0]])
        #expect(hiddenAddresses == [first, second])

        let overriding = wire { $0.clefOverrides = [second: "F", first: "G8vb"] }
        let overrides = overriding.clefOverrides.map { "\($0.partIndex)/\($0.staffIndexInPart)/\($0.rawType)" }
        let overrideMap = overriding.clefOverrideMap
        #expect(overrides == ["0/1/G8vb", "1/0/F"])
        #expect(overrideMap == [first: "G8vb", second: "F"])
    }

    @Test("the break policy, nil meaning no opinion")
    func breakPolicy() {
        let noOpinion = wire { $0.breakPolicy = nil }
        #expect(noOpinion.breakPolicyRaw == 0)
        let expected: [(LayoutBreakPolicy, UInt8)] = [(.honor, 1), (.ignoreSystemBreaks, 2), (.ignoreAll, 3)]
        for (policy, raw) in expected {
            let sent = wire { $0.breakPolicy = policy }
            #expect(sent.breakPolicyRaw == raw, "\(policy)")
            #expect(sent.breakPolicy == policy, "\(policy)")
        }
    }

    @Test("multi-measure rests: the switch and the minimum")
    func multiMeasureRests() {
        let collapsing = wire { $0.collapsesMultiMeasureRests = true }
        #expect(collapsing.collapseMultiMeasureRests == 1)
        #expect(collapsing.multiMeasureRestPolicy == .collapse(minimumMeasures: 2))
        let fourOrMore = wire {
            $0.collapsesMultiMeasureRests = true
            $0.multiMeasureRestMinimum = 4
        }
        #expect(fourOrMore.multiMeasureRestMinimum == 4)
        #expect(fourOrMore.multiMeasureRestPolicy == .collapse(minimumMeasures: 4))
    }

    @Test("measure numbers")
    func measureNumbers() {
        let everyFifth = wire { $0.measureNumbers = .interval(every: 5) }
        #expect(everyFifth.measureNumberInterval == 5)
        #expect(everyFifth.measureNumberPolicy == .interval(every: 5))
        let everyMeasure = wire { $0.measureNumbers = .everyMeasure }
        #expect(everyMeasure.measureNumberInterval == 1)
        // Below 1 is every measure, as the policy reads it — never the wire's 0, which is system heads only.
        let everyZeroth = wire { $0.measureNumbers = .interval(every: 0) }
        #expect(everyZeroth.measureNumberInterval == 1)
    }

    @Test("the system gap, the title block and the magnifications, nil meaning the engine's own")
    func optionalScalars() {
        let gapped = wire { $0.systemGapPoints = 30 }
        #expect(gapped.systemGapPoints == 30)
        #expect(gapped.systemGap(staffSize: 28) == 30)
        let untitled = wire { $0.includesTitleFrame = false }
        #expect(untitled.includeTitleFrameRaw == 0)
        #expect(!untitled.includesTitleFrame(modeDefault: true))
        let titled = wire { $0.includesTitleFrame = true }
        #expect(titled.includeTitleFrameRaw == 1)
        #expect(titled.includesTitleFrame(modeDefault: false))
        let smallGraces = wire { $0.graceNoteMag = 0.5 }
        #expect(smallGraces.graceNoteMag == 0.5)
        let largeCues = wire { $0.smallNoteMag = 0.8 }
        #expect(largeCues.smallNoteMag == 0.8)
    }

    @Test("break-indicator visibility")
    func breakIndicators() {
        let expected: [(BreakIndicatorVisibility, UInt8)] = [(.none, 0), (.pageOnly, 1), (.all, 2)]
        for (visibility, raw) in expected {
            let sent = wire { $0.breakIndicatorVisibility = visibility }
            #expect(sent.breakIndicatorVisibilityRaw == raw, "\(visibility)")
            #expect(sent.breakIndicatorVisibility == visibility, "\(visibility)")
        }
    }

    @Test("each spacing field reaches its own wire field, and only that one")
    func spacing() {
        let fields: [(
            name: String,
            options: WritableKeyPath<ScorePageOptions.Spacing, Double?>,
            wire: KeyPath<EngravingSpacingWire, Double?>,
        )] = [
            ("minNoteDistance", \.minNoteDistance, \.minNoteDistance),
            ("spacePerQuarter", \.spacePerQuarter, \.spacePerQuarter),
            ("systemStretch", \.systemStretch, \.systemStretch),
            ("marginTop", \.marginTop, \.marginTop),
            ("marginLeading", \.marginLeading, \.marginLeading),
            ("marginBottom", \.marginBottom, \.marginBottom),
            ("marginTrailing", \.marginTrailing, \.marginTrailing),
            ("firstSystemIndent", \.firstSystemIndent, \.firstSystemIndent),
            ("continuationSystemIndent", \.continuationSystemIndent, \.continuationSystemIndent),
            ("minStaffGap", \.minStaffGap, \.minStaffGap),
            ("systemVerticalPadding", \.systemVerticalPadding, \.systemVerticalPadding),
        ]
        for field in fields {
            let sent = wire { $0.spacing[keyPath: field.options] = 3.5 }.spacing
            let value = sent?[keyPath: field.wire]
            let others = fields.filter { $0.name != field.name }.compactMap { sent?[keyPath: $0.wire] }
            #expect(value == 3.5, "\(field.name)")
            #expect(others.isEmpty, "\(field.name) set another field too: \(others)")
        }
    }

    // MARK: - Helpers

    /// The wire of the default options with `change` applied.
    private func wire(_ change: (inout ScorePageOptions) -> Void) -> LayoutOptionsWire {
        var options = ScorePageOptions.default
        change(&options)
        return options.wire()
    }

    /// Every field of the two wires, one by one: the wire types are not `Equatable`.
    private func expectSame(_ actual: LayoutOptionsWire, _ expected: LayoutOptionsWire) {
        let hidden = (actual.hiddenStaffAddresses, expected.hiddenStaffAddresses)
        let clefs = (actual.clefOverrideMap, expected.clefOverrideMap)
        let spacing = (actual.spacing == nil, expected.spacing == nil)
        #expect(actual.layoutMode == expected.layoutMode)
        #expect(actual.staffSize == expected.staffSize)
        #expect(actual.collapseMultiMeasureRests == expected.collapseMultiMeasureRests)
        #expect(actual.showsInvisibleElements == expected.showsInvisibleElements)
        #expect(actual.hiddenStaves.count == expected.hiddenStaves.count)
        #expect(hidden.0 == hidden.1)
        #expect(actual.clefOverrides.count == expected.clefOverrides.count)
        #expect(clefs.0 == clefs.1)
        #expect(actual.transposeSemitones == expected.transposeSemitones)
        #expect(actual.showsLyrics == expected.showsLyrics)
        #expect(actual.breakPolicyRaw == expected.breakPolicyRaw)
        #expect(actual.multiMeasureRestMinimum == expected.multiMeasureRestMinimum)
        #expect(actual.measureNumberInterval == expected.measureNumberInterval)
        #expect(actual.systemGapPoints == expected.systemGapPoints)
        #expect(actual.includeTitleFrameRaw == expected.includeTitleFrameRaw)
        #expect(actual.breakIndicatorVisibilityRaw == expected.breakIndicatorVisibilityRaw)
        #expect(actual.graceNoteMag == expected.graceNoteMag)
        #expect(actual.smallNoteMag == expected.smallNoteMag)
        #expect(spacing.0 == spacing.1, "one side sends spacing, the other does not")
    }
}
