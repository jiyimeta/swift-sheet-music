import { describe, expect, it } from "vitest";
import type { DrawProgramPage } from "../src/draw-program.js";
import { MAX_CANVAS_DIMENSION_PX, planPageTiles } from "../src/render/tiles.js";

function pageOfHeight(heightMM: number): DrawProgramPage {
  return { widthMM: 210, heightMM, commands: [] };
}

/** What Examples/Web draws at: 96 dpi doubled for sharpness. */
const PX_PER_MM = (96 / 25.4) * 2;

describe("planPageTiles", () => {
  it("leaves a page that fits as a single tile", () => {
    const tiles = planPageTiles(pageOfHeight(297), PX_PER_MM);
    expect(tiles).toHaveLength(1);
    expect(tiles[0]!.offsetMM).toBe(0);
    expect(tiles[0]!.heightMM).toBe(297);
  });

  it("splits a page taller than the canvas limit", () => {
    // A 6-part score laid out continuously: 17,931.6 mm is 135,546 px at this
    // scale, and Chromium silently draws nothing above 65,535.
    const tiles = planPageTiles(pageOfHeight(17931.6), PX_PER_MM);
    expect(tiles.length).toBeGreaterThan(1);
    for (const tile of tiles) {
      expect(tile.heightMM * PX_PER_MM).toBeLessThanOrEqual(
        MAX_CANVAS_DIMENSION_PX,
      );
    }
  });

  it("covers the page exactly, with no gap and no overlap", () => {
    const heightMM = 17931.6;
    const tiles = planPageTiles(pageOfHeight(heightMM), PX_PER_MM);
    expect(tiles[0]!.offsetMM).toBe(0);
    for (let i = 1; i < tiles.length; i += 1) {
      expect(tiles[i]!.offsetMM).toBeCloseTo(
        tiles[i - 1]!.offsetMM + tiles[i - 1]!.heightMM,
        9,
      );
    }
    const last = tiles[tiles.length - 1]!;
    expect(last.offsetMM + last.heightMM).toBeCloseTo(heightMM, 9);
  });

  it("uses the full limit rather than splitting more than it has to", () => {
    const tiles = planPageTiles(pageOfHeight(17931.6), PX_PER_MM);
    const expected = Math.ceil(
      (17931.6 * PX_PER_MM) / MAX_CANVAS_DIMENSION_PX,
    );
    expect(tiles).toHaveLength(expected);
  });

  it("handles a page exactly at the limit without splitting", () => {
    const exactMM = MAX_CANVAS_DIMENSION_PX / PX_PER_MM;
    expect(planPageTiles(pageOfHeight(exactMM), PX_PER_MM)).toHaveLength(1);
  });

  it("splits a page one pixel over the limit into two", () => {
    const overMM = (MAX_CANVAS_DIMENSION_PX + 1) / PX_PER_MM;
    expect(planPageTiles(pageOfHeight(overMM), PX_PER_MM)).toHaveLength(2);
  });

  it("scales with pxPerMM rather than with millimetres", () => {
    const page = pageOfHeight(10000);
    // Half the resolution, half the pixels, so at most half as many tiles.
    const dense = planPageTiles(page, PX_PER_MM);
    const sparse = planPageTiles(page, PX_PER_MM / 2);
    expect(sparse.length).toBeLessThan(dense.length);
  });

  it("rejects a page too wide to draw at this scale", () => {
    // Nothing can be done about width by slicing vertically, so it is an error
    // rather than a silently blank canvas.
    const tooWide: DrawProgramPage = {
      widthMM: MAX_CANVAS_DIMENSION_PX / PX_PER_MM + 1,
      heightMM: 100,
      commands: [],
    };
    expect(() => planPageTiles(tooWide, PX_PER_MM)).toThrow(/width/i);
  });
});
