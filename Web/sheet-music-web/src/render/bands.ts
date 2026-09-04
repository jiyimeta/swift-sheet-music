import type { DrawCommand, DrawProgramPage } from "../draw-program.js";

/**
 * One horizontal slice of a page's draw program.
 *
 * A direct port of
 * `Android/SheetMusicComposeAndroid/.../render/ScoreBands.kt`.
 * Divergences from it are bugs — same contract as `canvas.ts` against
 * `ScoreCanvas.kt`.
 */
export interface ScoreBand {
  /** Top of the band's TRUE painted extent (not a grid cell), document mm. */
  readonly topMM: number;
  readonly heightMM: number;
  /**
   * Self-contained: opens with the paint state (color, dash) in force where
   * the band starts. Coordinates stay in PAGE space.
   */
  readonly commands: readonly DrawCommand[];
}

/** Default band height (document mm). Mirrors DEFAULT_BAND_HEIGHT_MM. */
export const DEFAULT_BAND_HEIGHT_MM = 80;

/** Paint color a draw program starts from, matching the renderer's initial Paint. */
const INITIAL_ARGB = 0xff000000;

/**
 * Split this page's command stream into bands of at least `minBandHeightMM`
 * painted height.
 *
 * A band closes at the first command boundary past that height where closing is
 * safe: no path is mid-construction and no rotation is open. Paint state is
 * restated at each band's start, so each band can be replayed independently.
 */
export function splitIntoBands(
  page: DrawProgramPage,
  minBandHeightMM: number = DEFAULT_BAND_HEIGHT_MM,
): ScoreBand[] {
  if (page.commands.length === 0) return [];

  const bands: ScoreBand[] = [];
  let buffer: DrawCommand[] = [];
  let minY = Number.POSITIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;

  let argb = INITIAL_ARGB;
  let dashOnMM = 0;
  let dashOffMM = 0;
  let textStyleFlags = 0;
  let pathOpen = false;
  let rotation: Extract<DrawCommand, { kind: "setRotation" }> | null = null;

  const startBuffer = (): void => {
    buffer = [{ kind: "setColor", argb }];
    if (dashOnMM !== 0 || dashOffMM !== 0) {
      buffer.push({ kind: "setDash", onMM: dashOnMM, offMM: dashOffMM });
    }
    // Restated for the same reason colour and dash are: the band cut happens
    // BEFORE a command is appended, so it can land between a `setTextStyle` and
    // the text it styles, and the second band would then draw a bold rehearsal
    // mark at regular weight inside a frame sized for bold.
    if (textStyleFlags !== 0) {
      buffer.push({ kind: "setTextStyle", flags: textStyleFlags });
    }
    minY = Number.POSITIVE_INFINITY;
    maxY = Number.NEGATIVE_INFINITY;
  };

  const flush = (): void => {
    if (minY <= maxY) bands.push({ topMM: minY, heightMM: maxY - minY, commands: buffer });
    startBuffer();
  };

  startBuffer();

  for (const command of page.commands) {
    if (!pathOpen && rotation === null && minY <= maxY && maxY - minY >= minBandHeightMM) {
      flush();
    }

    switch (command.kind) {
      case "setColor":
        argb = command.argb;
        break;
      case "setDash":
        dashOnMM = command.onMM;
        dashOffMM = command.offMM;
        break;
      case "setTextStyle":
        textStyleFlags = command.flags;
        break;
      case "setRotation":
        rotation = command.radians !== 0 ? command : null;
        break;
      case "moveTo":
        pathOpen = true;
        break;
      case "stroke":
        pathOpen = false;
        break;
    }

    buffer.push(command);

    if (command.kind === "stroke") {
      if (minY <= maxY) {
        minY -= command.width;
        maxY += command.width;
      }
      continue;
    }

    const box = boxMM(command);
    if (box === null) continue;
    const [extentTop, extentBottom] = box.verticalExtent(rotation);
    minY = Math.min(minY, extentTop);
    maxY = Math.max(maxY, extentBottom);
  }

  flush();
  return bands;
}

/** Axis-aligned bounds of one command in document mm, before rotation. */
class Box {
  constructor(
    private readonly minX: number,
    private readonly minY: number,
    private readonly maxX: number,
    private readonly maxY: number,
  ) {}

  /**
   * Vertical extent once `rotation` is applied. A rotated point stays within
   * its distance from the pivot, so the extent collapses to that radius about
   * the pivot's Y.
   */
  verticalExtent(
    rotation: Extract<DrawCommand, { kind: "setRotation" }> | null,
  ): [number, number] {
    if (rotation === null) return [this.minY, this.maxY];
    const px = rotation.pivotX;
    const py = rotation.pivotY;
    const radius = Math.max(
      Math.hypot(this.minX - px, this.minY - py),
      Math.hypot(this.maxX - px, this.minY - py),
      Math.hypot(this.minX - px, this.maxY - py),
      Math.hypot(this.maxX - px, this.maxY - py),
    );
    return [py - radius, py + radius];
  }
}

/**
 * Bounds this command paints, or null for state-only commands.
 *
 * Deliberately generous: under-reporting would let a host cull a band whose ink
 * reaches into the viewport, while over-reporting only costs culling efficiency.
 */
function boxMM(command: DrawCommand): Box | null {
  switch (command.kind) {
    case "moveTo":
    case "lineTo":
      return new Box(command.x, command.y, command.x, command.y);
    case "cubicTo":
      return new Box(
        Math.min(command.cx1, command.cx2, command.x),
        Math.min(command.cy1, command.cy2, command.y),
        Math.max(command.cx1, command.cx2, command.x),
        Math.max(command.cy1, command.cy2, command.y),
      );
    case "fillRect":
      return new Box(command.x, command.y, command.x + command.w, command.y + command.h);
    case "glyph":
    case "text":
    case "italicText":
      return new Box(
        command.x,
        command.y - 2 * command.size,
        command.x + 2 * command.size,
        command.y + command.size,
      );
    case "stretchedGlyph":
      return new Box(
        command.rightEdgeX - command.fontSize,
        command.topY,
        command.rightEdgeX,
        command.bottomY,
      );
    // State commands paint nothing themselves, so they contribute no box.
    case "stroke":
    case "setColor":
    case "setDash":
    case "setRotation":
    case "setTextStyle":
      return null;
  }
}
