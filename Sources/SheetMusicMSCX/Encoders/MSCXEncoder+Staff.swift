import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Staff {
    /// Encode the per-Part `<Staff>` declaration block — staff type,
    /// bracket information, default clef. Measures are emitted by
    /// `encodeTopLevel(staffID:)` separately.
    func encodeDeclaration(
        staffID: String, options: MSCXEncoderOptions = .init()
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(
            name: "StaffType",
            attributes: ["group": group],
            children: [
                XMLTreeNode(name: "name", text: staffType),
            ]
        ))
        if let defaultClefType {
            children.append(XMLTreeNode(
                name: "defaultClef", text: defaultClefType
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
                name: "bracket", attributes: bracketAttrs
            ))
        }
        return XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: children
        )
    }

    /// Encode the top-level `<Staff id="N">` block carrying measures.
    /// Pass `titleFrame` to prepend a `<VBox>` ahead of the measures —
    /// MuseScore stores the title block inside the first top-level
    /// staff body, so callers should set it only on staff index 0 of
    /// part index 0.
    func encodeTopLevel(
        staffID: String,
        titleFrame: ScoreFrame? = nil,
        options: MSCXEncoderOptions = .init()
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
            let result = try measure.encode(
                carryInVoiceTieCarries: carry,
                isFirstMeasureOfStaff: measureIndex == 0,
                options: options
            )
            children.append(result.node)
            carry = result.carryOutVoiceTieCarries
        }
        return XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: children
        )
    }
}
