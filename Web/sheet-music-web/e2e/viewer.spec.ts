import { expect, test } from "@playwright/test";

const FIXTURE = "/Web/sheet-music-web/test/fixtures/sample.mscz";

/**
 * Fails the test on any page error or console error, not just on a wrong
 * screenshot. A viewer that throws while booting still renders a blank canvas,
 * which a diff against an empty baseline would happily accept.
 */
test.beforeEach(async ({ page }) => {
  const failures: string[] = [];
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") failures.push(message.text());
  });
  await page.goto("/Examples/Web/");
  await expect(page.locator("body")).toHaveAttribute("data-engine-ready", "true");
  expect(failures).toEqual([]);
});

test("reports a ready engine", async ({ page }) => {
  await expect(page.locator("#status")).toContainText("ready");
});

test("reads the score's metadata", async ({ page }) => {
  await page.evaluate((url) => window.renderScoreFromURL(url), FIXTURE);
  await expect(page.locator("body")).toHaveAttribute("data-page-count", /[1-9]/);
  await expect(page.locator("#status")).toContainText("web parity");
  await expect(page.locator("#status")).toContainText("♩ = 120");
});

test("draws ink rather than an empty canvas", async ({ page }) => {
  await page.evaluate((url) => window.renderScoreFromURL(url), FIXTURE);
  await page.evaluate(() => document.fonts.ready);
  const inked = await page.evaluate(() => {
    const canvas = document.querySelector("canvas") as HTMLCanvasElement;
    const ctx = canvas.getContext("2d")!;
    const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
    let count = 0;
    for (let i = 0; i < data.length; i += 4) {
      // The canvas starts transparent and the engraver paints in black, so any
      // opaque dark pixel is ink.
      if (data[i + 3]! > 128 && data[i]! < 200) count += 1;
    }
    return count;
  });
  // A blank page is the failure mode when fonts or metrics do not load, and it
  // is indistinguishable from success in a diff against a blank baseline.
  expect(inked).toBeGreaterThan(1000);
});

test("engraves the fixture the same way as last time", async ({ page }) => {
  await page.evaluate((url) => window.renderScoreFromURL(url), FIXTURE);
  await expect(page.locator("body")).toHaveAttribute("data-page-count", /[1-9]/);
  // Fonts are registered before the engine reports ready, but Chromium can
  // still be rasterizing the first glyph run when the canvas is filled.
  await page.evaluate(() => document.fonts.ready);
  await expect(page.locator("canvas").first()).toHaveScreenshot("first-page.png");
});
