/**
 * Splits a tall page into canvas-sized slices.
 *
 * The engraver's `.vertical` layout — the only mode the bridge exposes today —
 * returns one continuous page whose height is the whole document. A six-part
 * score runs to about 18 metres, which at 2× screen resolution is 135,546
 * pixels, and **a canvas taller than 65,535 pixels silently draws nothing** in
 * Chromium: no exception, no clamping, `getContext` and `getImageData` both
 * succeed, and every pixel comes back transparent. Measured on Chromium 151:
 * 65,535 draws, 65,536 does not.
 *
 * So anything past roughly 8.7 metres — around 47 A4 pages — has to be tiled
 * across several canvases. That is not an optimization; it is the difference
 * between a viewer that works on real scores and one that works on examples.
 * Android solves the same problem with `ScoreBands.kt`.
 */
import type { DrawProgramPage } from "../draw-program.js";

/**
 * The largest canvas dimension Chromium will actually draw into.
 *
 * Other engines differ — Safari and Firefox have their own, generally lower,
 * area limits — but they fail the same way, so the smallest known safe bound is
 * the useful one to design against. Raising this needs measurement, not a
 * changelog entry.
 */
export const MAX_CANVAS_DIMENSION_PX = 65535;

/** One horizontal slice of a page, in document millimetres. */
export interface PageTile {
  /** Distance from the top of the page to the top of this slice. */
  readonly offsetMM: number;
  /** Height of this slice. */
  readonly heightMM: number;
}

/**
 * Plan the slices needed to draw `page` at `pxPerMM`.
 *
 * Returns a single full-height tile when the page already fits, so a caller
 * never needs to special-case the common one-canvas path. Tiles are contiguous
 * and cover the page exactly — no gaps, no overlap — because a seam that
 * repeats or drops a row of pixels is visible on a staff line.
 *
 * @throws if the page is too wide to draw at this scale. Slicing vertically
 * cannot help with width, and the alternative is a blank canvas with nothing to
 * explain it.
 */
export function planPageTiles(
  page: DrawProgramPage,
  pxPerMM: number,
): PageTile[] {
  const widthPx = page.widthMM * pxPerMM;
  if (widthPx > MAX_CANVAS_DIMENSION_PX) {
    throw new Error(
      `page width ${page.widthMM} mm is ${Math.round(widthPx)} px at this ` +
        `scale, past the ${MAX_CANVAS_DIMENSION_PX} px canvas limit — ` +
        `reduce pxPerMM`,
    );
  }

  const maxTileMM = MAX_CANVAS_DIMENSION_PX / pxPerMM;
  if (page.heightMM <= maxTileMM) {
    return [{ offsetMM: 0, heightMM: page.heightMM }];
  }

  const count = Math.ceil(page.heightMM / maxTileMM);
  // Divide evenly rather than filling each tile to the limit and leaving a
  // sliver at the end: equal-height canvases allocate more predictably, and the
  // seams land in consistent places.
  const heightMM = page.heightMM / count;
  const tiles: PageTile[] = [];
  for (let i = 0; i < count; i += 1) {
    tiles.push({ offsetMM: i * heightMM, heightMM });
  }
  return tiles;
}
