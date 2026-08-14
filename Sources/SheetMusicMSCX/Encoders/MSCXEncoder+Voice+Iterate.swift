import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Read-only bookkeeping shared across `iterate` calls. Bundled
    /// so the main encode function stays under the function-body-length
    /// limit after sys-element interleaving was added.
    struct IterationPlan {
        let startsByIndex: [Int: [Tuplet]]
        let endCountByIndex: [Int: Int]
        let lastChordIndex: Int?
        let voiceBarLength: Fraction
        let effectiveDuration: Fraction
        let dropInitialZeroKeySig: Bool
        /// For each chord-bearing element index, the note list of the
        /// chord a forward tie there would land on — the next
        /// chord-bearing element in this voice, or the next measure's
        /// first one when this is the last. Feeds the `<notes>` half of
        /// the tie's `<location>`; see `TieEndpoint`. Absent where the
        /// partner is unknown (no following chord anywhere), in which
        /// case the delta stays `0`.
        let forwardTiePartnerNotes: [Int: ChordNotes]
    }

    /// One iteration of the main encode loop: open any tuplets that
    /// start at this index, emit the voice element (unless it's a
    /// suppressed staff-head zero-keysig), then close any tuplets
    /// that end at this index. System-element interleaving is the
    /// caller's responsibility — it happens after `iterate` returns.
    func iterate(
        element: VoiceElement,
        index: Int,
        plan: IterationPlan,
        carryIn: VoiceTieCarry,
        state: inout EncodeState,
        options: MSCXEncoderOptions,
        staffGroup: String,
        voiceIndex: Int,
    ) throws {
        for opening in plan.startsByIndex[index] ?? [] {
            let activeWithOpening = state.stack + [opening]
            let base = tupletBaseDuration(
                opening: opening,
                activeTuplets: activeWithOpening,
            )
            state.children.append(opening.encode(baseDuration: base))
            state.stack.append(opening)
        }
        if !(plan.dropInitialZeroKeySig && index == 0) {
            try emitElement(
                element: element,
                index: index,
                plan: plan,
                carryIn: carryIn,
                state: &state,
                options: options,
                staffGroup: staffGroup,
                voiceIndex: voiceIndex,
            )
        }
        for _ in 0 ..< (plan.endCountByIndex[index] ?? 0) {
            state.stack.removeLast()
            state.children.append(XMLTreeNode(name: "endTuplet"))
        }
    }
}
