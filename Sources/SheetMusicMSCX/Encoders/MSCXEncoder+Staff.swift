import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Staff {
    /// Encode the per-Part `<Staff>` declaration block — staff type,
    /// bracket information, default clef. Measures are emitted by
    /// `encodeTopLevel(staffID:)` separately.
    func encodeDeclaration(
        staffID: String, options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(
            name: "StaffType",
            attributes: ["group": group],
            children: [
                XMLTreeNode(name: "name", text: staffType),
            ],
        ))
        if let defaultClefType {
            children.append(XMLTreeNode(
                name: "defaultClef", text: defaultClefType,
            ))
        }
        for bracket in brackets {
            var bracketAttrs: [String: String] = [
                "type": String(bracket.type.rawValue),
                "span": String(bracket.span),
                "col": String(bracket.column),
            ]
            if !bracket.visible { bracketAttrs["visible"] = "0" }
            children.append(XMLTreeNode(
                name: "bracket", attributes: bracketAttrs,
            ))
        }
        return XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: children,
        )
    }

    /// Encode the top-level `<Staff id="N">` block carrying measures.
    /// Pass `titleFrame` to prepend a `<VBox>` ahead of the measures —
    /// MuseScore stores the title block inside the first top-level
    /// staff body, so callers should set it only on staff index 0 of
    /// part index 0.
    ///
    /// `systemElementsByMeasure[i]` (when supplied) is the set of
    /// system elements destined for this staff at measure index `i`.
    /// They're injected into voice 0 of that measure as voice
    /// elements with `<location>` shifts to match their
    /// `MeasurePosition`. Empty or out-of-range entries skip the
    /// injection.
    /// `effectiveMeasureDurations[i]` is the effective duration of
    /// measure `i` (from `[Measure].effectiveMeasureDurations()`),
    /// forwarded to each measure's encoder so `.measure` rests can
    /// resolve against the prevailing TimeSignature × actualLength.
    /// An empty array (the default) keeps the historical 4/4
    /// fallback for source-compat — safe until decoders start
    /// emitting `.measure` rests.
    func encodeTopLevel(
        staffID: String,
        titleFrame: ScoreFrame? = nil,
        systemElementsByMeasure: [[PositionedSystemElement]] = [],
        effectiveMeasureDurations: [Fraction] = [],
        options: MSCXEncoderOptions = .init(),
    ) throws -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let titleFrame {
            children.append(titleFrame.encodeAsVBox())
        }
        // Thread per-voice tie-carry data across measures so a tie
        // that crosses a measure boundary can encode the
        // `<measures>±1</measures>` form (which MuseScore Studio
        // requires to disambiguate cross-bar ties from same-bar
        // offsets — the same-`<fractions>`-only encoding makes
        // MuseScore match the wrong destination chord).
        var carry: [Voice.VoiceTieCarry] = []
        for (measureIndex, measure) in measures.enumerated() {
            let injection: [PositionedSystemElement] =
                measureIndex < systemElementsByMeasure.count
                    ? systemElementsByMeasure[measureIndex]
                    : []
            let measureDuration = measureIndex < effectiveMeasureDurations.count
                ? effectiveMeasureDurations[measureIndex]
                : Fraction(numerator: 4, denominator: 4)
            let result = try measure.encode(
                carryInVoiceTieCarries: carry,
                isFirstMeasureOfStaff: measureIndex == 0,
                options: options,
                staffGroup: group,
                voice0SystemElements: injection,
                effectiveDuration: measureDuration,
            )
            children.append(result.node)
            carry = result.carryOutVoiceTieCarries
        }
        return XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: children,
        )
    }
}
