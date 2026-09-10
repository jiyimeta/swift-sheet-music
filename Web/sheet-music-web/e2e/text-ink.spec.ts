import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

// Independent raster oracle: the shipped table must bound the pixels drawn by
// the real renderer, including stroke-before-shear for bold italic.
test("styled text ink agrees with the shipped table and restores Canvas state", async ({ page }) => {
  const font = readFileSync(new URL("../assets/edwin-roman.woff2", import.meta.url)).toString("base64");
  const table = [...readFileSync(new URL("../assets/sheet-music.smft", import.meta.url))];
  await page.goto("/Web/sheet-music-web/");
  const results = await page.evaluate(async ({ font, table }) => {
    const { drawPage } = await import("/Web/sheet-music-web/dist-esm/render/canvas.js");
    const face = new FontFace("InkOracleEdwin", `url(data:font/woff2;base64,${font})`);
    await face.load(); document.fonts.add(face);
    const bytes = new Uint8Array(table);
    const view = new DataView(bytes.buffer); let offset = 16;
    const u32 = () => { const value = view.getUint32(offset, true); offset += 4; return value; };
    const f32 = () => { const value = view.getFloat32(offset, true); offset += 4; return value; };
    const records: Record<string, Record<number, number[]>> = {};
    const count = u32();
    for (let i = 0; i < count; i++) {
      const length = u32(); const name = new TextDecoder().decode(bytes.slice(offset, offset + length)); offset += length;
      offset += 12; const glyphs = u32(); records[name] = {};
      for (let j = 0; j < glyphs; j++) { const cp = u32(); records[name][cp] = [f32(), f32(), f32(), f32(), f32()]; }
    }
    const results = [];
    for (let flags = 0; flags < 4; flags++) for (const text of ["A", "g"]) {
      const canvas = document.createElement("canvas"); canvas.width = 1800; canvas.height = 1600;
      const ctx = canvas.getContext("2d")!;
      ctx.lineWidth = 9; ctx.lineJoin = "bevel"; ctx.strokeStyle = "red"; ctx.setLineDash([4, 2]);
      const following: unknown[][] = [];
      const fillText = ctx.fillText.bind(ctx);
      ctx.fillText = (value, x, y) => {
        if (value === " ") following.push([ctx.lineWidth, ctx.lineJoin, ...ctx.getLineDash(), ctx.getTransform().c, ctx.font]);
        fillText(value, x, y);
      };
      const stroke = ctx.stroke.bind(ctx);
      ctx.stroke = () => { following.push([ctx.lineWidth, ctx.lineJoin, ctx.getTransform().c]); stroke(); };
      drawPage(ctx, { widthMM: 1800, heightMM: 1600, commands: [
        { kind: "setTextStyle", flags },
        { kind: "text", text, x: 300, y: 1100, size: 1000, fontId: 0 },
        { kind: "setTextStyle", flags: 0 },
        { kind: "glyph", codepoint: 32, x: 0, y: 0, size: 10, fontId: 1 },
        { kind: "stroke", width: 9 },
      ] }, 1, { smufl: "Bravura", textRoman: "InkOracleEdwin" });
      const pixels = ctx.getImageData(0, 0, 1800, 1600).data;
      let left = 1800, top = 1600, right = -1, bottom = -1;
      for (let y = 0; y < 1600; y++) for (let x = 0; x < 1800; x++) {
        if (pixels[(y * 1800 + x) * 4 + 3] < 128) continue;
        left = Math.min(left, x); top = Math.min(top, y); right = Math.max(right, x + 1); bottom = Math.max(bottom, y + 1);
      }
      const name = ["Edwin", "Edwin-Bold", "Edwin-Italic", "Edwin-BoldItalic"][flags];
      const [, x, y, width, height] = records[name][text.codePointAt(0)!];
      results.push({ name, text, raster: [left, top, right, bottom], ink: [300 + x, 1100 - y - height, 300 + x + width, 1100 - y],
        following, state: [ctx.lineWidth, ctx.lineJoin, ctx.strokeStyle, ...ctx.getLineDash(), ctx.getTransform().c] });
    }
    return results;
  }, { font, table });
  expect(results).toHaveLength(8);
  for (const result of results) {
    for (let edge = 0; edge < 4; edge++) expect(Math.abs(result.raster[edge] - result.ink[edge]), `${result.name} ${result.text} edge ${edge}`).toBeLessThan(2);
    expect(result.state).toEqual([9, "bevel", "#ff0000", 4, 2, 0]);
    expect(result.following).toEqual([[9, "bevel", 4, 2, 0, "10px Bravura"], [9, "bevel", 0]]);
  }
});
