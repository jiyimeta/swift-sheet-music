/**
 * Browser and Node facade over the wasm bridge.
 *
 * `loadSheetMusic` is async even though everything under it is synchronous, so
 * that moving work onto a Worker later could not break hosts. That move is NOT
 * planned: the measurements in `docs/development/webassembly.md` say a renderer
 * Worker would have nothing to protect, and moving `computeLayout` would mean
 * moving the whole bridge and turning every cursor, hit-test and caret query
 * into a postMessage round trip. The async signature is headroom that was kept,
 * not a migration that is pending.
 */
import {
  decodeDrawProgram,
  type DrawProgramPage,
} from "./draw-program.js";
import {
  applyEditIntentCall,
  type CaretRect,
  type EditIntent,
  type EditOutcome,
  type EditSessionState,
  type SelectedItem,
  type SelectedItemKind,
} from "./edit.js";

export type {
  DrawCommand,
  DrawProgramPage,
  FontId,
} from "./draw-program.js";
export type {
  AccidentalSpec,
  CaretRect,
  EditIntent,
  EditOutcome,
  EditSessionState,
  ElementRef,
  NoteDurationSpec,
  NoteRef,
  SelectedItem,
  SelectedItemKind,
} from "./edit.js";
export {
  drawPage,
  drawTile,
  DEFAULT_TILE_HEIGHT_PX,
  loadScoreFonts,
  MAX_CANVAS_DIMENSION_PX,
  planPageTiles,
  planViewportTiles,
  reconcileMounts,
  splitIntoBands,
} from "./render/canvas.js";
export type {
  DrawPageOptions,
  FontURLs,
  MountWindow,
  PageTile,
  ScoreBand,
  ScoreFonts,
} from "./render/canvas.js";

/** What the host shows in a title bar or a document list. */
export interface ScoreMetadata {
  readonly title: string;
  readonly composer: string;
  readonly partCount: number;
  readonly staffCount: number;
  /**
   * The tempo governing the start, in quarter-note BPM. MuseScore's 120 default
   * when the score sets none.
   */
  readonly openingQuarterBpm: number;
}

export interface LayoutRequest {
  /** Viewport / page width in document millimetres. */
  readonly pageWidthMM: number;
  /** Page height in document millimetres. */
  readonly pageHeightMM: number;
  readonly options?: LayoutOptions;
}

export type LayoutMode = "vertical" | "horizontal" | "page";

export interface HiddenStaff {
  readonly partIndex: number;
  readonly staffIndexInPart: number;
}

export interface ClefOverride {
  readonly partIndex: number;
  readonly staffIndexInPart: number;
  readonly clef: string;
}

/**
 * Display settings for one layout pass. All fields are optional; omitted values
 * resolve to `LayoutOptionsWire.verticalDefault`.
 */
export interface LayoutOptions {
  readonly layoutMode?: LayoutMode;
  readonly staffSize?: number;
  readonly honorLayoutBreaks?: boolean;
  readonly collapseMultiMeasureRests?: boolean;
  readonly showsInvisibleElements?: boolean;
  readonly showsLyrics?: boolean;
  readonly transposeSemitones?: number;
  readonly hiddenStaves?: readonly HiddenStaff[];
  readonly clefOverrides?: readonly ClefOverride[];
}

interface ResolvedLayoutOptions {
  readonly layoutMode: number;
  readonly staffSize: number;
  readonly honorLayoutBreaks: boolean;
  readonly collapseMultiMeasureRests: boolean;
  readonly showsInvisibleElements: boolean;
  readonly showsLyrics: boolean;
  readonly transposeSemitones: number;
  readonly hiddenStaves: readonly HiddenStaff[];
  readonly clefOverrides: readonly ClefOverride[];
}

/**
 * What a transport UI needs before the first frame is drawn.
 *
 * Two lengths, not one. `totalNotatedSeconds` is the score's own; the synth
 * plays the UNROLLED sequence, whose length is `totalPlayerSeconds` and which is
 * longer on any score with repeats. Every position this package hands back or
 * takes in for playback is on the *player* clock unless its name says otherwise.
 */
export interface PlaybackSummary {
  readonly totalNotatedSeconds: number;
  readonly totalPlayerSeconds: number;
  readonly measureCount: number;
  /** Ticks per quarter note. */
  readonly division: number;
  /** The tempo governing the start, in quarter-note BPM. */
  readonly openingQuarterBpm: number;
}

/** Durable playback position in notated score coordinates. */
export interface ScorePosition {
  readonly measureIndex: number;
  readonly tickInMeasure: number;
}

/**
 * Where to draw the playback cursor, in document millimetres — the same unit
 * the draw program uses, so one `pxPerMM` scales both.
 */
export interface CursorRect {
  readonly xMM: number;
  readonly yMM: number;
  readonly widthMM: number;
  readonly heightMM: number;
  /** The measure the cursor is parked in. */
  readonly measureIndex: number;
  /**
   * The position on the score's own clock — differs from the player position
   * that produced it on any score with repeats.
   */
  readonly notatedSeconds: number;
}

/** One rehearsal mark with its player-clock seek target. */
export interface RehearsalMarkInfo {
  readonly text: string;
  readonly measureIndex: number;
  readonly playerSeconds: number;
}

/** One staff flattened out of the score's part -> staves descriptor. */
export interface StaffDescriptor {
  readonly partIndex: number;
  readonly staffIndexInPart: number;
  readonly partName: string;
  readonly isPartVisibleInScore: boolean;
  readonly defaultClefRawType: string;
}

/** A document rectangle in millimetres. */
export interface MeasureFrame {
  readonly xMM: number;
  readonly yMM: number;
  readonly widthMM: number;
  readonly heightMM: number;
}

/** A measure range to loop over. `toMeasureExclusive` may equal the count. */
export interface MeasureRange {
  readonly fromMeasureIndex: number;
  readonly toMeasureExclusive: number;
}

/**
 * One mixer strip: a deduped (part × instrument) pair and the MIDI channel its
 * program, volume and mute route through.
 *
 * **`program` and `volume` have to be asserted before playing.** The sequence
 * `renderMidi` returns carries neither on a mixer-managed channel — both are
 * stripped so a backward seek cannot replay them over a live override — so a
 * host that skips this hears General MIDI's default patch, Acoustic Grand
 * Piano, on every melodic channel. `PlaybackEngine` does it for you; a host
 * driving a synth directly must do it itself. Percussion hides the mistake:
 * channel 9 picks the drum bank whatever the program says.
 */
export interface MixerStrip {
  readonly partIndex: number;
  /** Index into the part's deduped instruments, in first-appearance order. */
  readonly ordinal: number;
  /** The MIDI channel (0–15) this strip sounds on. */
  readonly channel: number;
  readonly bank: number;
  /** GM patch number, 0–127. */
  readonly program: number;
  /** Percussion. Its program is meaningless — do not offer a patch picker. */
  readonly isDrums: boolean;
  /** The score's own CC 7, 0–127 — the balance the composer wrote. */
  readonly volume: number;
  readonly displayName: string;
}

/**
 * The raw `@JS` surface BridgeJS exposes. Not part of this package's API — the
 * generated declarations live in the built bundle, which is not present at
 * type-check time, so the shape is restated here and pinned by the parity test.
 */
interface BridgeEditSessionState {
  readonly active: boolean;
  readonly canUndo: boolean;
  readonly canRedo: boolean;
  readonly hasLastAffected: boolean;
  readonly lastAffectedPartIndex: number;
  readonly lastAffectedStaffIndexInPart: number;
  readonly lastAffectedMeasureIndex: number;
  readonly lastAffectedVoiceIndex: number;
  readonly lastAffectedElementIndex: number;
}

export interface BridgeExports {
  applyEditIntentBytes(handle: number, intentBytes: Uint8Array): EditOutcome;
  editingHitTest(
    handle: number,
    xMM: number,
    yMM: number,
    activeVoice: number,
  ): SelectedItem | null;
  editingCaretRect(
    handle: number,
    kind: string,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    noteIndexInChord: number,
    minimumWidthMM: number,
  ): CaretRect | null;
  editInputNote(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    pitch: number,
    tpc: number,
    durationKind: number,
    durationNumerator: number,
    durationDenominator: number,
  ): EditOutcome;
  editWriteNote(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    pitch: number,
    tpc: number,
    durationKind: number,
    durationNumerator: number,
    durationDenominator: number,
  ): EditOutcome;
  editSetNotePitch(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    noteIndexInChord: number,
    pitch: number,
    tpc: number,
    accidental: string,
  ): EditOutcome;
  editSetAccidental(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    noteIndexInChord: number,
    accidental: string,
  ): EditOutcome;
  editAddNoteToChord(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    pitch: number,
    tpc: number,
    accidental: string,
  ): EditOutcome;
  editRemoveNoteFromChord(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    noteIndexInChord: number,
  ): EditOutcome;
  editSetTie(
    handle: number,
    fromPartIndex: number,
    fromStaffIndexInPart: number,
    fromMeasureIndex: number,
    fromVoiceIndex: number,
    fromElementIndex: number,
    fromNoteIndexInChord: number,
    toPartIndex: number,
    toStaffIndexInPart: number,
    toMeasureIndex: number,
    toVoiceIndex: number,
    toElementIndex: number,
    toNoteIndexInChord: number,
    hasSourceTieForward: number,
    sourceTieForward: number,
    hasTargetTieBack: number,
    targetTieBack: number,
  ): EditOutcome;
  editWriteRest(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    durationKind: number,
    durationNumerator: number,
    durationDenominator: number,
  ): EditOutcome;
  editSetRestDuration(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    durationKind: number,
    durationNumerator: number,
    durationDenominator: number,
  ): EditOutcome;
  editSetChordDuration(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    durationKind: number,
    durationNumerator: number,
    durationDenominator: number,
  ): EditOutcome;
  editDelete(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
  ): EditOutcome;
  editCreateTuplet(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
    actualNotes: number,
    normalNotes: number,
  ): EditOutcome;
  editRemoveTuplet(
    handle: number,
    partIndex: number,
    staffIndexInPart: number,
    measureIndex: number,
    voiceIndex: number,
    elementIndex: number,
  ): EditOutcome;
  beginEditSession(handle: number): boolean;
  endEditSession(handle: number): void;
  editUndo(handle: number): EditOutcome;
  editRedo(handle: number): EditOutcome;
  editSessionState(handle: number): BridgeEditSessionState;
  engineVersionStamp(): string;
  loadScore(bytes: Uint8Array): number;
  releaseScore(handle: number): void;
  scoreMetadata(handle: number): ScoreMetadata | null;
  rehearsalMarkCount(handle: number): number;
  rehearsalMark(handle: number, index: number): RehearsalMarkInfo | null;
  staffDescriptorCount(handle: number): number;
  staffDescriptor(handle: number, index: number): StaffDescriptor | null;
  scoreFingerprint(handle: number): string;
  installSMuFLMetrics(bytes: Uint8Array): boolean;
  computeLayout(
    handle: number,
    pageWidthMM: number,
    pageHeightMM: number,
    options: ResolvedLayoutOptions,
  ): Uint8Array;
  pageBreaks(handle: number, pageHeightMM: number): number[] | Float64Array;
  renderMidi(handle: number): Uint8Array;
  renderMetronomeMidi(handle: number): Uint8Array;
  renderCountInMetronomeMidi(
    handle: number,
    fromPlayerSeconds: number,
  ): Uint8Array;
  countInSeconds(handle: number, fromPlayerSeconds: number): number;
  playerSecondsAtPoint(handle: number, xMM: number, yMM: number): number;
  playbackSummary(handle: number): PlaybackSummary | null;
  metronomeBeats(handle: number): number[] | Float64Array;
  cursorRectAtPlayerSeconds(
    handle: number,
    playerSeconds: number,
  ): CursorRect | null;
  measureFrame(handle: number, measureIndex: number): number[] | Float64Array;
  playerSecondsForMeasure(handle: number, measureIndex: number): number;
  playerSecondsForPosition(
    handle: number,
    measureIndex: number,
    tickInMeasure: number,
  ): number;
  positionAtPlayerSeconds(
    handle: number,
    playerSeconds: number,
  ): number[] | Float64Array;
  measureIndexAtPlayerSeconds(handle: number, playerSeconds: number): number;
  loopPlayerSeconds(
    handle: number,
    fromMeasureIndex: number,
    toMeasureExclusive: number,
  ): number[] | Float64Array;
  loopHighlightRects(
    handle: number,
    fromMeasureIndex: number,
    toMeasureExclusive: number,
  ): number[] | Float64Array;
  buildClickSoundFont(strongWav: Uint8Array, weakWav: Uint8Array): Uint8Array;
  mixerStripCount(handle: number): number;
  mixerStrip(handle: number, index: number): MixerStrip | null;
  gmInstrumentNames(): string[];
  gmInstrumentFamilies(): string[];
  masterTuningControlChanges(cents: number): number[] | Float64Array;
}

/** One General MIDI patch: its program number, name and family. */
export interface GMInstrument {
  readonly program: number;
  readonly name: string;
  /** One of the sixteen GM families — "Piano", "Bass", "Synth Lead", … */
  readonly family: string;
}

function asDoubles(value: number[] | Float64Array): Float64Array {
  return value instanceof Float64Array ? value : Float64Array.from(value);
}

function resolveLayoutMode(mode: LayoutMode | undefined): number {
  switch (mode) {
    case undefined:
    case "vertical":
      return 0;
    case "horizontal":
      return 1;
    case "page":
      return 2;
  }
}

function resolveOptions(options: LayoutOptions | undefined): ResolvedLayoutOptions {
  return {
    layoutMode: resolveLayoutMode(options?.layoutMode),
    staffSize: options?.staffSize ?? 28,
    honorLayoutBreaks: options?.honorLayoutBreaks ?? true,
    collapseMultiMeasureRests: options?.collapseMultiMeasureRests ?? false,
    showsInvisibleElements: options?.showsInvisibleElements ?? false,
    showsLyrics: options?.showsLyrics ?? true,
    transposeSemitones: options?.transposeSemitones ?? 0,
    hiddenStaves: options?.hiddenStaves ?? [],
    clefOverrides: options?.clefOverrides ?? [],
  };
}

function isSelectedItemKind(kind: string): kind is SelectedItemKind {
  return kind === "note" || kind === "rest" || kind === "tuplet";
}

/**
 * One loaded score.
 *
 * The handle is owned by the caller: `release()` frees the score and its cached
 * layout inside wasm memory. Nothing collects it for you, so a viewer that
 * opens files in a loop and forgets leaks until the page is closed — the same
 * contract the Android bridge has.
 */
export class Score {
  private handle: number;
  private editGenerationValue = 0;

  constructor(
    private readonly bridge: BridgeExports,
    handle: number,
  ) {
    this.handle = handle;
  }

  private live(): number {
    if (this.handle === 0) {
      throw new Error("score has been released");
    }
    return this.handle;
  }

  get metadata(): ScoreMetadata {
    const metadata = this.bridge.scoreMetadata(this.live());
    if (metadata === null) {
      throw new Error("score has been released");
    }
    return metadata;
  }

  /**
   * FNV-1a digest with no per-process seed, so it equals the value an Apple or
   * Android build computes for the same score.
   *
   * A decimal string rather than a number: the digest is 64 bits and a
   * JavaScript number is an f64 that would round anything past 2^53.
   *
   * Scoped to the mutable musical content — notes, timing, spelling. Metadata is
   * not in it, so two scores that differ only by title share a fingerprint.
   * Treating this as "is this the same document" would be wrong.
   */
  get fingerprint(): string {
    return this.bridge.scoreFingerprint(this.live());
  }

  /**
   * Monotonic generation for the mutable score behind this handle.
   *
   * Bumps on every accepted apply / bytes relay / undo / redo. Playback engines
   * pin the value they were created with so a pre-edit SMF cannot keep sounding
   * while post-edit cursor geometry is queried from wasm.
   */
  get editGeneration(): number {
    return this.editGenerationValue;
  }

  /**
   * Android: nativeBeginEditSession. Idempotent; re-begin drops the undo stack.
   */
  beginEditing(): void {
    if (!this.bridge.beginEditSession(this.live())) {
      throw new Error("failed to begin edit session");
    }
  }

  /** Not a revert — the score keeps its last published state. */
  endEditing(): void {
    this.bridge.endEditSession(this.live());
  }

  /** One method over the typed union; routes to the per-case bridge entry point. */
  applyEdit(intent: EditIntent): EditOutcome {
    return this.bumpGenerationIfAccepted(
      applyEditIntentCall(this.bridge, this.live(), intent),
    );
  }

  /**
   * Relay path for EditIntentCodec bytes authored elsewhere. This is the only
   * way JavaScript can apply a composite intent.
   */
  applyEditIntentBytes(bytes: Uint8Array): EditOutcome {
    return this.bumpGenerationIfAccepted(
      this.bridge.applyEditIntentBytes(this.live(), bytes),
    );
  }

  undo(): EditOutcome {
    return this.bumpGenerationIfAccepted(this.bridge.editUndo(this.live()));
  }

  redo(): EditOutcome {
    return this.bumpGenerationIfAccepted(this.bridge.editRedo(this.live()));
  }

  editState(): EditSessionState {
    const state = this.bridge.editSessionState(this.live());
    return {
      active: state.active,
      canUndo: state.canUndo,
      canRedo: state.canRedo,
      lastAffected: state.hasLastAffected
        ? {
            partIndex: state.lastAffectedPartIndex,
            staffIndexInPart: state.lastAffectedStaffIndexInPart,
            measureIndex: state.lastAffectedMeasureIndex,
            voiceIndex: state.lastAffectedVoiceIndex,
            elementIndex: state.lastAffectedElementIndex,
          }
        : null,
    };
  }

  /**
   * Editing hit-test, in document millimetres.
   *
   * This is a HIT-TEST with slop rescue, not the nearest-match
   * `playerSecondsAtPoint`: empty paper returns `null` so a tap can deselect.
   */
  hitTest(xMM: number, yMM: number, activeVoice = 0): SelectedItem | null {
    const item = this.bridge.editingHitTest(
      this.live(),
      xMM,
      yMM,
      activeVoice,
    );
    if (item === null) return null;
    if (!isSelectedItemKind(item.kind)) {
      throw new Error(`unknown edit hit kind: ${item.kind}`);
    }
    return item;
  }

  /**
   * Caret geometry for a full-score-addressed selected item.
   *
   * Returns `null` until `layout()` has run since the last accepted edit. The
   * bridge drops its layout cache on publish, so host order is accepted edit,
   * then `layout()`, then geometry.
   */
  caretRect(item: SelectedItem, minimumWidthMM = 0): CaretRect | null {
    return this.bridge.editingCaretRect(
      this.live(),
      item.kind,
      item.partIndex,
      item.staffIndexInPart,
      item.measureIndex,
      item.voiceIndex,
      item.elementIndex,
      item.noteIndexInChord,
      minimumWidthMM,
    );
  }

  /** The `DrawProgramFlat` bytes, undecoded. Useful for parity checks. */
  layoutBytes(request: LayoutRequest): Uint8Array {
    const bytes = this.bridge.computeLayout(
      this.live(),
      request.pageWidthMM,
      request.pageHeightMM,
      resolveOptions(request.options),
    );
    if (bytes.length === 0) {
      throw new Error("layout failed");
    }
    return bytes;
  }

  layout(request: LayoutRequest): DrawProgramPage[] {
    return decodeDrawProgram(this.layoutBytes(request));
  }

  /**
   * Page-boundary document-Y offsets in millimetres, `[0, …, contentBottom]`.
   *
   * Requires a prior `layout()` for the same score — the boundaries are read off
   * the cached document rather than engraved afresh, which is what keeps the
   * call cheap. Returns an empty array otherwise.
   */
  pageBreaks(request: { readonly pageHeightMM: number }): number[] {
    return Array.from(this.bridge.pageBreaks(this.live(), request.pageHeightMM));
  }

  /**
   * The Standard MIDI File a synth plays: the live channel plan applied, and the
   * baked-in CC 7 / tick-0 program stripped off every mixer-owned channel so a
   * live mixer is the sole authority.
   */
  renderMidi(): Uint8Array {
    return this.bridge.renderMidi(this.live());
  }

  /**
   * The metronome's own sequence — the score's tempo map plus the click track.
   *
   * A second sequence rather than clicks merged into the score's, because that
   * is what makes muting the metronome a gain change: reloading a merged
   * sequence would cut every voice sounding on the score side.
   */
  renderMetronomeMidi(): Uint8Array {
    return this.bridge.renderMetronomeMidi(this.live());
  }

  /**
   * The metronome sequence with a count-in in front: the pre-roll's clicks fill
   * `[0, countInSeconds)` and the body's clicks sit behind them, so one
   * sequencer plays the count and then the piece.
   *
   * Empty when the position has no count-in.
   */
  renderCountInMetronomeMidi(fromPlayerSeconds: number): Uint8Array {
    return this.bridge.renderCountInMetronomeMidi(
      this.live(),
      fromPlayerSeconds,
    );
  }

  /**
   * How long the count-in for `fromMeasureIndex` lasts. `0` means "start now".
   *
   * Watch the metronome sequencer's own position against this rather than
   * waiting it out with `setTimeout` — a wall-clock wait quantizes the downbeat
   * to whichever output buffer noticed the deadline, which is audible.
   */
  countInSeconds(fromPlayerSeconds: number): number {
    return this.bridge.countInSeconds(this.live(), fromPlayerSeconds);
  }

  /**
   * The player position a tap lands on, for seeking by clicking the score.
   *
   * Coordinates are document millimetres — the same ones the draw program and
   * `cursorRectAtPlayerSeconds` use, so scale a pointer event by the `pxPerMM`
   * you already render with.
   *
   * NEAREST, not a hit-test: a tap beside a note resolves to the closest
   * playable element rather than to nothing, which is what makes this usable
   * with a finger. `-1` only when no layout has been computed or the score has
   * nothing playable in it.
   */
  playerSecondsAtPoint(xMM: number, yMM: number): number {
    return this.bridge.playerSecondsAtPoint(this.live(), xMM, yMM);
  }

  playbackSummary(): PlaybackSummary | null {
    return this.bridge.playbackSummary(this.live());
  }

  /**
   * One strip per deduped (part × instrument) pair, in score order.
   *
   * Read this before playing: the strips carry the programs and volumes the
   * rendered sequence deliberately does not. See `MixerStrip`.
   */
  /**
   * The MIDI control changes that retune an RPN-honoring synth by `cents` from
   * A4=440, flattened as `[controller, value, …]` and in send order.
   *
   * Send them per channel — the RPN is a channel parameter. `PlaybackEngine`
   * does this for you through `setMasterTuning`; this is here for a host
   * driving a synth directly. The split between coarse semitones and fine cents
   * is the engine's, so a calibration means the same thing on iOS and Android.
   */
  masterTuningControlChanges(cents: number): Float64Array {
    return asDoubles(this.bridge.masterTuningControlChanges(cents));
  }

  mixerStrips(): MixerStrip[] {
    const handle = this.live();
    const count = this.bridge.mixerStripCount(handle);
    const strips: MixerStrip[] = [];
    for (let index = 0; index < count; index++) {
      const strip = this.bridge.mixerStrip(handle, index);
      if (strip !== null) strips.push(strip);
    }
    return strips;
  }

  /**
   * Rehearsal marks in score order, with player-clock seek targets.
   *
   * Every mark the score carries is listed. `playerSeconds` is `-1` for one
   * whose cursor does not resolve — the list is a navigation index, so a
   * missing letter would be worse than an entry that cannot be seeked to.
   */
  rehearsalMarks(): RehearsalMarkInfo[] {
    const handle = this.live();
    const count = this.bridge.rehearsalMarkCount(handle);
    const marks: RehearsalMarkInfo[] = [];
    for (let index = 0; index < count; index++) {
      const mark = this.bridge.rehearsalMark(handle, index);
      if (mark !== null) marks.push(mark);
    }
    return marks;
  }

  /** Staff descriptors flattened across parts in score order. */
  staffDescriptors(): StaffDescriptor[] {
    const handle = this.live();
    const count = this.bridge.staffDescriptorCount(handle);
    const descriptors: StaffDescriptor[] = [];
    for (let index = 0; index < count; index++) {
      const descriptor = this.bridge.staffDescriptor(handle, index);
      if (descriptor !== null) descriptors.push(descriptor);
    }
    return descriptors;
  }

  /**
   * Click positions for a visual beat indicator, flattened as
   * `[playerSeconds, isDownbeat, …]` — two entries per beat, the flag `1` or
   * `0`.
   *
   * Only for showing beats. The clicks themselves are events in
   * `renderMetronomeMidi`'s sequence.
   */
  metronomeBeats(): Float64Array {
    return asDoubles(this.bridge.metronomeBeats(this.live()));
  }

  /**
   * Where to draw the cursor for a position on the player's clock, or `null`
   * when no layout has been computed for this score — the cached document is
   * what turns a position into geometry, so call `layout()` first.
   */
  cursorRectAtPlayerSeconds(playerSeconds: number): CursorRect | null {
    return this.bridge.cursorRectAtPlayerSeconds(this.live(), playerSeconds);
  }

  /**
   * The bounding rectangle of a measure in document millimetres, or `null`
   * until `layout()` has run or when the index is outside the document.
   */
  measureFrame(measureIndex: number): MeasureFrame | null {
    const frame = asDoubles(this.bridge.measureFrame(this.live(), measureIndex));
    if (frame.length !== 4) return null;
    return {
      xMM: frame[0]!,
      yMM: frame[1]!,
      widthMM: frame[2]!,
      heightMM: frame[3]!,
    };
  }

  /**
   * The player position a measure starts at — a seek target. `-1` for an
   * out-of-range index, which `0` could not express: that is the top of the
   * score, a real position.
   */
  playerSecondsForMeasure(measureIndex: number): number {
    return this.bridge.playerSecondsForMeasure(this.live(), measureIndex);
  }

  /**
   * The player-clock seconds for a durable score position. `-1` means the
   * position does not resolve.
   */
  playerSecondsForPosition(position: ScorePosition): number {
    return this.bridge.playerSecondsForPosition(
      this.live(),
      position.measureIndex,
      position.tickInMeasure,
    );
  }

  /**
   * The durable score position sounding at `playerSeconds`, or `null` when it
   * does not resolve.
   */
  positionAtPlayerSeconds(playerSeconds: number): ScorePosition | null {
    const position = asDoubles(
      this.bridge.positionAtPlayerSeconds(this.live(), playerSeconds),
    );
    if (position.length !== 2) return null;
    return {
      measureIndex: position[0]!,
      tickInMeasure: position[1]!,
    };
  }

  /** The measure sounding at a player position, or `-1` for an empty score. */
  measureIndexAtPlayerSeconds(playerSeconds: number): number {
    return this.bridge.measureIndexAtPlayerSeconds(this.live(), playerSeconds);
  }

  /**
   * `[startSeconds, endSeconds]` on the player clock for a measure-range loop,
   * or an empty array for an empty or inverted range.
   *
   * The wrap is the host's job: a sequencer's own loop covers the whole
   * sequence, not a range inside it.
   */
  loopPlayerSeconds(range: MeasureRange): Float64Array {
    return asDoubles(
      this.bridge.loopPlayerSeconds(
        this.live(),
        range.fromMeasureIndex,
        range.toMeasureExclusive,
      ),
    );
  }

  /**
   * Rectangles to tint for a measure-range loop, flattened as
   * `[x, y, width, height, …]` in document millimetres — one per system the
   * range spans, so a loop crossing a line break highlights both halves.
   *
   * Empty until `layout()` has run for this score.
   */
  loopHighlightRects(range: MeasureRange): Float64Array {
    return asDoubles(
      this.bridge.loopHighlightRects(
        this.live(),
        range.fromMeasureIndex,
        range.toMeasureExclusive,
      ),
    );
  }

  release(): void {
    if (this.handle !== 0) {
      this.bridge.releaseScore(this.handle);
      this.handle = 0;
    }
  }

  private bumpGenerationIfAccepted(outcome: EditOutcome): EditOutcome {
    if (outcome.accepted) {
      this.editGenerationValue += 1;
    }
    return outcome;
  }
}

export class SheetMusic {
  constructor(private readonly bridge: BridgeExports) {}

  /**
   * This wasm image's build identity, as a decimal string. Compare it with a
   * cached copy's before trusting the cache. A string for the same reason
   * `Score.fingerprint` is one.
   */
  engineVersionStamp(): string {
    return this.bridge.engineVersionStamp();
  }

  /**
   * Install the Bravura glyph-metrics table. Ship
   * `@jiyimeta/sheet-music-web/assets/bravura.smft`.
   *
   * Not optional in practice: without it the engraver falls back to rectangle
   * approximations and the spacing is visibly wrong — but it still engraves, so
   * nothing else will tell you.
   */
  installSMuFLMetrics(bytes: Uint8Array): boolean {
    return this.bridge.installSMuFLMetrics(bytes);
  }

  /**
   * Build a bank-128 SoundFont from two click WAVs, mapping the strong click to
   * note 76 and the weak one to note 77 — the notes the metronome sequence
   * plays.
   *
   * Load it into the metronome's synth ahead of the score's General MIDI bank to
   * replace the GM wood blocks with your own clicks. Empty when either WAV fails
   * to parse, which means "keep the GM clicks".
   */
  buildClickSoundFont(strongWav: Uint8Array, weakWav: Uint8Array): Uint8Array {
    return this.bridge.buildClickSoundFont(strongWav, weakWav);
  }

  /**
   * The 128 General MIDI patches, in program order — for a mixer's patch
   * picker.
   *
   * The same table the iOS and Android libraries use, read out of the engine
   * rather than transcribed here: a second copy of 128 names is a second thing
   * to get wrong, and it would take a long time for anyone to notice.
   *
   * A constant, so cache the result — every call re-crosses the bridge.
   */
  gmInstruments(): GMInstrument[] {
    const names = this.bridge.gmInstrumentNames();
    const families = this.bridge.gmInstrumentFamilies();
    return names.map((name, program) => ({
      program,
      name,
      family: families[program] ?? "",
    }));
  }

  /**
   * Parse `.mscx` / `.mscz` / `.musicxml` / `.mxl` / `.mid` — the format is
   * sniffed from the leading bytes.
   */
  loadScore(bytes: Uint8Array): Score {
    const handle = this.bridge.loadScore(bytes);
    if (handle === 0) {
      throw new Error("failed to parse score");
    }
    return new Score(this.bridge, handle);
  }
}

/**
 * The PackageToJS-generated bundle, imported dynamically so this package
 * type-checks without it having been built.
 */
interface GeneratedBundle {
  instantiate(options: unknown): Promise<{ exports: BridgeExports }>;
  defaultNodeSetup(options?: unknown): Promise<unknown>;
  defaultBrowserSetup(options: unknown): Promise<unknown>;
}

export interface LoadOptions {
  /**
   * Directory holding the output of `Scripts/wasm-build-web.sh` — the one
   * containing `instantiate.js`, `platforms/` and the `.wasm`.
   */
  readonly bundleURL: URL | string;
  /**
   * Which host setup to use. Defaults to `node` when `process.versions.node` is
   * present and `browser` otherwise, which is right for every case except a
   * bundler pretending to be Node.
   */
  readonly platform?: "browser" | "node";
}

function defaultPlatform(): "browser" | "node" {
  const maybeProcess = (globalThis as { process?: { versions?: { node?: string } } })
    .process;
  return maybeProcess?.versions?.node !== undefined ? "node" : "browser";
}

/** Instantiate the wasm module and return the facade. */
export async function loadSheetMusic(
  options: LoadOptions,
): Promise<SheetMusic> {
  const base = new URL(
    typeof options.bundleURL === "string"
      ? options.bundleURL
      : options.bundleURL.href,
  );
  // A directory URL must end in a slash or `new URL(relative, base)` resolves
  // against its parent.
  if (!base.pathname.endsWith("/")) {
    base.pathname += "/";
  }
  const platform = options.platform ?? defaultPlatform();

  const instantiateModule = (await import(
    /* @vite-ignore */ new URL("instantiate.js", base).href
  )) as GeneratedBundle;

  let setup: unknown;
  if (platform === "node") {
    const nodeModule = (await import(
      /* @vite-ignore */ new URL("platforms/node.js", base).href
    )) as GeneratedBundle;
    setup = await nodeModule.defaultNodeSetup({});
  } else {
    const browserModule = (await import(
      /* @vite-ignore */ new URL("platforms/browser.js", base).href
    )) as GeneratedBundle;
    setup = await browserModule.defaultBrowserSetup({
      module: fetch(new URL("sheet-music-wasm.wasm", base)),
      getImports: () => ({}),
    });
  }

  const { exports } = await instantiateModule.instantiate(setup);
  return new SheetMusic(exports);
}
