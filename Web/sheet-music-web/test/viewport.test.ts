import { describe, expect, it } from "vitest";
import type { DrawProgramPage } from "../src/draw-program.js";
import {
  MAX_CANVAS_DIMENSION_PX,
  planViewportTiles,
  reconcileMounts,
} from "../src/render/canvas.js";

function pageOfHeight(heightMM: number): DrawProgramPage {
  return { widthMM: 210, heightMM, commands: [] };
}

function tileIds(count: number): ReadonlySet<number> {
  return new Set(Array.from({ length: count }, (_, index) => index));
}

/** What Examples/Web draws at: 96 dpi doubled for sharpness. */
const PX_PER_MM = (96 / 25.4) * 2;

describe("planViewportTiles", () => {
  it("cuts to the requested mount height even when the page fits one canvas", () => {
    const tiles = planViewportTiles(pageOfHeight(1757), PX_PER_MM, 1024);

    expect(tiles).toHaveLength(13);
    expect(tiles[0]!.offsetMM).toBe(0);
    expect(tiles[0]!.heightMM * PX_PER_MM).toBeCloseTo(1021.6354, 3);
    expect(
      tiles[tiles.length - 1]!.offsetMM + tiles[tiles.length - 1]!.heightMM,
    ).toBeCloseTo(1757, 9);
  });

  it("keeps every mount tile under Chromium's canvas dimension limit", () => {
    const targetPastCanvasLimit = MAX_CANVAS_DIMENSION_PX * 2;
    const tiles = planViewportTiles(
      pageOfHeight(17931.6),
      PX_PER_MM,
      targetPastCanvasLimit,
    );

    expect(tiles).toHaveLength(3);
    for (const tile of tiles) {
      expect(tile.heightMM * PX_PER_MM).toBeLessThanOrEqual(
        MAX_CANVAS_DIMENSION_PX,
      );
    }
  });
});

describe("reconcileMounts", () => {
  it("mounts the same number of tiles for longer documents at the same viewport", () => {
    const shortTiles = planViewportTiles(pageOfHeight(1757), PX_PER_MM, 1024);
    const longTiles = planViewportTiles(pageOfHeight(3318), PX_PER_MM, 1024);
    const window = { scrollTopMM: 500, viewportMM: 900 / PX_PER_MM };

    const shortMounts = reconcileMounts(shortTiles, window, new Set());
    const longMounts = reconcileMounts(longTiles, window, new Set());

    expect(shortMounts.mount.length).toBeGreaterThan(0);
    expect(longMounts.mount).toHaveLength(shortMounts.mount.length);
    expect(shortMounts.unmount).toEqual([]);
    expect(longMounts.unmount).toEqual([]);
  });

  it("keeps a mounted tile through a one millimetre round trip at the mount threshold", () => {
    const tiles = planViewportTiles(pageOfHeight(300), 1, 100);
    const pastThreshold = { scrollTopMM: 201, viewportMM: 100 };
    const backAtThreshold = { scrollTopMM: 200, viewportMM: 100 };

    const afterForward = reconcileMounts(
      tiles,
      pastThreshold,
      tileIds(tiles.length),
    );
    const afterBack = reconcileMounts(
      tiles,
      backAtThreshold,
      tileIds(tiles.length),
    );

    expect(afterForward.unmount).toEqual([]);
    expect(afterBack.mount).toEqual([]);
    expect(afterBack.unmount).toEqual([]);
  });
});
