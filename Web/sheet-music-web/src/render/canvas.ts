/**
 * Paints a decoded draw-program page onto a Canvas2D context.
 *
 * A direct port of
 * `Android/SheetMusicComposeAndroid/.../render/ScoreCanvas.kt`'s `drawCommands`.
 * Divergences from it are bugs: the two renderers consume the same commands from
 * the same engraver, so anything that looks different is one of them being
 * wrong.
 *
 * All coordinates in a draw program are document millimetres; every one is
 * multiplied by `pxPerMM`. Drawing at a zoomed `pxPerMM` re-rasterizes glyphs at
 * the target resolution, so the score stays sharp at every zoom level — scale
 * the drawing, never the bitmap.
 */
import type { DrawCommand, DrawProgramPage } from "../draw-program.js";
import { FontId } from "../draw-program.js";
import type { ScoreFonts } from "./fonts.js";

export type { FontURLs, ScoreFonts } from "./fonts.js";
export { loadScoreFonts } from "./fonts.js";
export type { PageTile } from "./tiles.js";
export { MAX_CANVAS_DIMENSION_PX, planPageTiles } from "./tiles.js";

/**
 * Minimum stroke width in device pixels. Mirrors the Kotlin renderer's
 * `coerceAtLeast(1.5f)`: without it, staff lines and stems vanish when zoomed
 * out, because a sub-pixel stroke antialiases to nothing.
 */
const MIN_STROKE_PX = 1.5;

/**
 * Italic slant, as the horizontal-shear term of a 2D transform.
 *
 * Android sets `Paint.textSkewX = -0.25f`, which leans the top of each glyph to
 * the right. Canvas2D has no text-skew property, so the equivalent is a shear
 * matrix. The sign is opposite to Android's because `textSkewX` multiplies by a
 * y that grows downward while the shear term here multiplies by the same y with
 * the opposite convention; it is pinned by the screenshot comparison in
 * `Web/sheet-music-web/e2e` rather than by argument.
 */
const ITALIC_SHEAR = 0.25;

/** Packed ARGB (0xAARRGGBB) to a CSS colour. */
function rgba(argb: number): string {
  const a = ((argb >>> 24) & 0xff) / 255;
  const r = (argb >>> 16) & 0xff;
  const g = (argb >>> 8) & 0xff;
  const b = argb & 0xff;
  return `rgba(${r}, ${g}, ${b}, ${Math.round(a * 1000) / 1000})`;
}

function faceFor(fontId: number, fonts: ScoreFonts): string {
  return fontId === FontId.smufl ? fonts.smufl : fonts.textRoman;
}

export interface DrawPageOptions {
  /**
   * Distance in document millimetres from the top of the page to the top of
   * this canvas.
   *
   * Pass a tile's `offsetMM` (see `planPageTiles`) to draw one slice of a page
   * too tall for a single canvas. Everything is still drawn — the canvas clips
   * what falls outside — so a slice costs a full command walk. Skipping
   * out-of-range commands would mean tracking which state opcodes
   * (`setColor`, `setDash`, `setRotation`) precede the slice, which is what
   * Android's `ScoreBands.kt` does and what this deliberately does not, yet.
   */
  readonly offsetMM?: number;
}

/**
 * Paint one page, or one slice of it.
 *
 * The caller owns the canvas: size its backing store to
 * `page.widthMM * pxPerMM` by `page.heightMM * pxPerMM` and clear it first if it
 * is being reused. Past `MAX_CANVAS_DIMENSION_PX` a canvas silently draws
 * nothing, so a tall page has to be tiled — see `planPageTiles`. The context is
 * handed back in the state it arrived in.
 */
export function drawPage(
  ctx: CanvasRenderingContext2D,
  page: DrawProgramPage,
  pxPerMM: number,
  fonts: ScoreFonts,
  options: DrawPageOptions = {},
): void {
  const offsetPx = (options.offsetMM ?? 0) * pxPerMM;
  let currentArgb = 0xff000000;
  let dashOnPx = 0;
  let dashOffPx = 0;
  let rotationOpen = false;

  const applyColor = (): void => {
    const css = rgba(currentArgb);
    ctx.fillStyle = css;
    ctx.strokeStyle = css;
  };

  const paint = (command: DrawCommand): void => {
    switch (command.kind) {
      case "moveTo":
        ctx.moveTo(command.x * pxPerMM, command.y * pxPerMM);
        break;
      case "lineTo":
        ctx.lineTo(command.x * pxPerMM, command.y * pxPerMM);
        break;
      case "cubicTo":
        ctx.bezierCurveTo(
          command.cx1 * pxPerMM,
          command.cy1 * pxPerMM,
          command.cx2 * pxPerMM,
          command.cy2 * pxPerMM,
          command.x * pxPerMM,
          command.y * pxPerMM,
        );
        break;
      case "stroke":
        ctx.lineWidth = Math.max(command.width * pxPerMM, MIN_STROKE_PX);
        ctx.setLineDash(
          dashOnPx > 0 && dashOffPx > 0 ? [dashOnPx, dashOffPx] : [],
        );
        ctx.stroke();
        ctx.beginPath();
        break;
      case "fillRect":
        ctx.fillRect(
          command.x * pxPerMM,
          command.y * pxPerMM,
          command.w * pxPerMM,
          command.h * pxPerMM,
        );
        break;
      case "glyph":
        ctx.font = `${command.size * pxPerMM}px "${faceFor(command.fontId, fonts)}"`;
        ctx.fillText(
          String.fromCodePoint(command.codepoint),
          command.x * pxPerMM,
          command.y * pxPerMM,
        );
        break;
      case "text":
        ctx.font = `${command.size * pxPerMM}px "${faceFor(command.fontId, fonts)}"`;
        ctx.fillText(command.text, command.x * pxPerMM, command.y * pxPerMM);
        break;
      case "italicText": {
        ctx.font = `${command.size * pxPerMM}px "${faceFor(command.fontId, fonts)}"`;
        const baselineY = command.y * pxPerMM;
        ctx.save();
        // Shear about the baseline so the glyph's foot stays where the engraver
        // put it and only the top leans. The `-shear * baselineY` translate is
        // what moves the shear's fixed line from y = 0 to the baseline.
        ctx.transform(1, 0, ITALIC_SHEAR, 1, -ITALIC_SHEAR * baselineY, 0);
        ctx.fillText(command.text, command.x * pxPerMM, baselineY);
        ctx.restore();
        break;
      }
      case "setColor":
        currentArgb = command.argb;
        applyColor();
        break;
      case "stretchedGlyph": {
        ctx.font = `${command.fontSize * pxPerMM}px "${faceFor(command.fontId, fonts)}"`;
        const glyph = String.fromCodePoint(command.codepoint);
        const metrics = ctx.measureText(glyph);
        const boxHeight =
          metrics.actualBoundingBoxAscent + metrics.actualBoundingBoxDescent;
        const boxRight = metrics.actualBoundingBoxRight;
        if (!(boxHeight > 0) || !(boxRight > 0)) break;
        const topPx = command.topY * pxPerMM;
        const bottomPx = command.bottomY * pxPerMM;
        const scaleY = (bottomPx - topPx) / boxHeight;
        // Rasterized ink bounds are the right measure here, unlike the metrics
        // table's geometric bounds: the Kotlin renderer uses
        // `Paint.getTextBounds` at this exact spot, and matching it is what puts
        // the brace in the same place on both platforms.
        ctx.save();
        ctx.translate(
          command.rightEdgeX * pxPerMM - command.xScale * boxRight,
          topPx + scaleY * metrics.actualBoundingBoxAscent,
        );
        ctx.scale(command.xScale, scaleY);
        ctx.fillText(glyph, 0, 0);
        ctx.restore();
        break;
      }
      case "setRotation":
        if (command.radians !== 0) {
          ctx.save();
          ctx.translate(command.pivotX * pxPerMM, command.pivotY * pxPerMM);
          ctx.rotate(command.radians);
          ctx.translate(-command.pivotX * pxPerMM, -command.pivotY * pxPerMM);
          rotationOpen = true;
        } else if (rotationOpen) {
          ctx.restore();
          rotationOpen = false;
        }
        break;
      case "setDash":
        dashOnPx = command.onMM * pxPerMM;
        dashOffPx = command.offMM * pxPerMM;
        break;
    }
  };

  // The slice offset rides on the context rather than being folded into every
  // coordinate, so `paint` stays a straight translation of the Kotlin renderer.
  // Balanced by the restore below.
  ctx.save();
  if (offsetPx !== 0) {
    ctx.translate(0, -offsetPx);
  }
  applyColor();
  ctx.beginPath();
  for (const command of page.commands) {
    paint(command);
  }
  // A page may end with a rotation still open — the Kotlin renderer's save-count
  // survives to the end of a band the same way. Close it so the caller's context
  // is not left transformed.
  if (rotationOpen) {
    ctx.restore();
  }
  ctx.restore();
}
