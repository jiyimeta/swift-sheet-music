import type { BridgeExports } from "./index.js";

export interface ElementRef {
  readonly partIndex: number;
  readonly staffIndexInPart: number;
  readonly measureIndex: number;
  readonly voiceIndex: number;
  readonly elementIndex: number;
}

export interface NoteRef extends ElementRef {
  readonly noteIndexInChord: number;
}

/**
 * Named kinds mirror NoteDuration; a fraction is spelled out. The numeric kinds
 * on the bridge match NoteDurationWire's table, and stay hidden here.
 */
export type NoteDurationSpec =
  | "whole"
  | "half"
  | "quarter"
  | "eighth"
  | "sixteenth"
  | "thirtySecond"
  | "sixtyFourth"
  | "oneTwentyEighth"
  | "twoFiftySixth"
  | "measure"
  | { readonly numerator: number; readonly denominator: number };

/** SMuFL accidental spelling, e.g. "accidentalSharp". null clears / omits the glyph. */
export type AccidentalSpec = string | null;

export type EditIntent =
  | { type: "inputNote"; at: ElementRef; pitch: number; tpc: number; duration?: NoteDurationSpec }
  | { type: "writeNote"; at: ElementRef; pitch: number; tpc: number; duration?: NoteDurationSpec }
  | { type: "writeRest"; at: ElementRef; duration: NoteDurationSpec }
  | { type: "setRestDuration"; at: ElementRef; duration: NoteDurationSpec }
  | { type: "setChordDuration"; at: ElementRef; duration: NoteDurationSpec }
  | { type: "delete"; at: ElementRef }
  | { type: "setNotePitch"; at: NoteRef; pitch: number; tpc: number; accidental?: AccidentalSpec }
  | { type: "setAccidental"; at: NoteRef; accidental: AccidentalSpec }
  | { type: "addNoteToChord"; at: ElementRef; pitch: number; tpc: number; accidental?: AccidentalSpec }
  | { type: "removeNoteFromChord"; at: NoteRef }
  | { type: "setTie"; from: NoteRef; to: NoteRef; sourceTieForward?: number | null; targetTieBack?: number | null }
  | { type: "createTuplet"; at: ElementRef; actualNotes: number; normalNotes: number }
  | { type: "removeTuplet"; at: ElementRef };

export interface EditOutcome {
  readonly accepted: boolean;
  readonly code: string;
  readonly operation: string;
  readonly message: string;
}

export interface EditSessionState {
  readonly active: boolean;
  readonly canUndo: boolean;
  readonly canRedo: boolean;
  readonly lastAffected: ElementRef | null;
}

export type SelectedItemKind = "note" | "rest" | "tuplet";

export interface SelectedItem {
  readonly kind: SelectedItemKind;
  readonly partIndex: number;
  readonly staffIndexInPart: number;
  readonly measureIndex: number;
  readonly voiceIndex: number;
  readonly elementIndex: number;
  readonly noteIndexInChord: number;
  readonly pitch: number;
  readonly tpc: number;
}

export interface CaretRect {
  readonly xMM: number;
  readonly yMM: number;
  readonly widthMM: number;
  readonly heightMM: number;
}

interface DurationWire {
  readonly kind: number;
  readonly numerator: number;
  readonly denominator: number;
}

const durationKinds: Record<Exclude<NoteDurationSpec, object>, number> = {
  whole: 1,
  half: 2,
  quarter: 3,
  eighth: 4,
  sixteenth: 5,
  thirtySecond: 6,
  sixtyFourth: 7,
  oneTwentyEighth: 8,
  twoFiftySixth: 9,
  measure: 10,
};

function durationWire(duration: NoteDurationSpec | undefined): DurationWire {
  if (duration === undefined) {
    return { kind: 0, numerator: 0, denominator: 0 };
  }
  if (typeof duration === "string") {
    return { kind: durationKinds[duration], numerator: 0, denominator: 0 };
  }
  return {
    kind: 11,
    numerator: duration.numerator,
    denominator: duration.denominator,
  };
}

function accidentalWire(accidental: AccidentalSpec | undefined): string {
  return accidental ?? "";
}

/** Exhaustive switch mapping the union to the 13 bridge calls. */
export function applyEditIntentCall(
  bridge: BridgeExports,
  handle: number,
  intent: EditIntent,
): EditOutcome {
  switch (intent.type) {
    case "inputNote": {
      const duration = durationWire(intent.duration);
      return bridge.editInputNote(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        intent.pitch,
        intent.tpc,
        duration.kind,
        duration.numerator,
        duration.denominator,
      );
    }
    case "writeNote": {
      const duration = durationWire(intent.duration);
      return bridge.editWriteNote(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        intent.pitch,
        intent.tpc,
        duration.kind,
        duration.numerator,
        duration.denominator,
      );
    }
    case "writeRest": {
      const duration = durationWire(intent.duration);
      return bridge.editWriteRest(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        duration.kind,
        duration.numerator,
        duration.denominator,
      );
    }
    case "setRestDuration": {
      const duration = durationWire(intent.duration);
      return bridge.editSetRestDuration(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        duration.kind,
        duration.numerator,
        duration.denominator,
      );
    }
    case "setChordDuration": {
      const duration = durationWire(intent.duration);
      return bridge.editSetChordDuration(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        duration.kind,
        duration.numerator,
        duration.denominator,
      );
    }
    case "delete":
      return bridge.editDelete(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
      );
    case "setNotePitch":
      return bridge.editSetNotePitch(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        intent.at.noteIndexInChord,
        intent.pitch,
        intent.tpc,
        accidentalWire(intent.accidental),
      );
    case "setAccidental":
      return bridge.editSetAccidental(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        intent.at.noteIndexInChord,
        accidentalWire(intent.accidental),
      );
    case "addNoteToChord":
      return bridge.editAddNoteToChord(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        intent.pitch,
        intent.tpc,
        accidentalWire(intent.accidental),
      );
    case "removeNoteFromChord":
      return bridge.editRemoveNoteFromChord(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        intent.at.noteIndexInChord,
      );
    case "setTie":
      return bridge.editSetTie(
        handle,
        intent.from.partIndex,
        intent.from.staffIndexInPart,
        intent.from.measureIndex,
        intent.from.voiceIndex,
        intent.from.elementIndex,
        intent.from.noteIndexInChord,
        intent.to.partIndex,
        intent.to.staffIndexInPart,
        intent.to.measureIndex,
        intent.to.voiceIndex,
        intent.to.elementIndex,
        intent.to.noteIndexInChord,
        intent.sourceTieForward === undefined || intent.sourceTieForward === null ? 0 : 1,
        intent.sourceTieForward ?? 0,
        intent.targetTieBack === undefined || intent.targetTieBack === null ? 0 : 1,
        intent.targetTieBack ?? 0,
      );
    case "createTuplet":
      return bridge.editCreateTuplet(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
        intent.actualNotes,
        intent.normalNotes,
      );
    case "removeTuplet":
      return bridge.editRemoveTuplet(
        handle,
        intent.at.partIndex,
        intent.at.staffIndexInPart,
        intent.at.measureIndex,
        intent.at.voiceIndex,
        intent.at.elementIndex,
      );
    default: {
      const exhaustive: never = intent;
      return exhaustive;
    }
  }
}
