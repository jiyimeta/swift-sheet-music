import type { DrawProgramPage } from "../draw-program.js";
import type { PageTile } from "./tiles.js";
import { MAX_CANVAS_DIMENSION_PX } from "./tiles.js";

/** Default mount-tile height in CSS pixels. One viewport-ish slice. */
export const DEFAULT_TILE_HEIGHT_PX = 1024;

export interface MountWindow {
  /** Document mm at the top of the viewport. */
  readonly scrollTopMM: number;
  /** Viewport height in document mm at the current scale. */
  readonly viewportMM: number;
}

/**
 * Split a page into mount-sized tiles.
 *
 * Unlike `planPageTiles`, which only cuts when a canvas would exceed
 * `MAX_CANVAS_DIMENSION_PX`, this cuts to a target height so a viewer can mount
 * and discard at a useful granularity. Still divides evenly, and still never
 * exceeds the canvas limit.
 *
 * @throws if the page is too wide to draw at this scale. Slicing vertically
 * cannot help with width, and the alternative is a blank canvas with nothing to
 * explain it.
 */
export function planViewportTiles(
  page: DrawProgramPage,
  pxPerMM: number,
  targetHeightPx: number = DEFAULT_TILE_HEIGHT_PX,
): PageTile[] {
  const widthPx = page.widthMM * pxPerMM;
  if (widthPx > MAX_CANVAS_DIMENSION_PX) {
    throw new Error(
      `page width ${page.widthMM} mm is ${Math.round(widthPx)} px at this ` +
        `scale, past the ${MAX_CANVAS_DIMENSION_PX} px canvas limit — ` +
        `reduce pxPerMM`,
    );
  }

  const effectiveTargetPx = Math.min(targetHeightPx, MAX_CANVAS_DIMENSION_PX);
  const count = Math.max(1, Math.ceil((page.heightMM * pxPerMM) / effectiveTargetPx));
  const heightMM = page.heightMM / count;
  const tiles: PageTile[] = [];
  for (let i = 0; i < count; i += 1) {
    tiles.push({ offsetMM: i * heightMM, heightMM });
  }
  return tiles;
}

/**
 * Which tiles should be mounted, and which currently-mounted ones should go.
 *
 * Mount reaches one viewport beyond the visible range; unmount only past two.
 * The gap is deliberate: a single threshold thrashes when a tile edge sits on
 * it, because mounting shifts nothing and the next scroll event re-tests the
 * same boundary.
 */
export function reconcileMounts(
  tiles: readonly PageTile[],
  window: MountWindow,
  mounted: ReadonlySet<number>,
): { readonly mount: readonly number[]; readonly unmount: readonly number[] } {
  const visibleTopMM = window.scrollTopMM;
  const visibleBottomMM = window.scrollTopMM + window.viewportMM;
  const mountTopMM = visibleTopMM - window.viewportMM;
  const mountBottomMM = visibleBottomMM + window.viewportMM;
  const unmountTopMM = visibleTopMM - 2 * window.viewportMM;
  const unmountBottomMM = visibleBottomMM + 2 * window.viewportMM;

  const mount: number[] = [];
  const unmount: number[] = [];

  for (let index = 0; index < tiles.length; index += 1) {
    const tile = tiles[index]!;
    if (mounted.has(index)) continue;
    if (intersects(tile, mountTopMM, mountBottomMM)) mount.push(index);
  }

  for (const index of mounted) {
    const tile = tiles[index];
    if (tile === undefined || !intersects(tile, unmountTopMM, unmountBottomMM)) {
      unmount.push(index);
    }
  }

  return { mount, unmount };
}

function intersects(
  tile: PageTile,
  topMM: number,
  bottomMM: number,
): boolean {
  const tileBottomMM = tile.offsetMM + tile.heightMM;
  return tileBottomMM > topMM && tile.offsetMM < bottomMM;
}
