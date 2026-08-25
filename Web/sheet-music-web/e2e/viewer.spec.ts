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
  await expect(page.locator("body")).toHaveAttribute("data-band-count", /[1-9]/);
  // Wiring only — the culling gate proper is `bridge.test.ts`'s ratio check
  // against the tall fixture. This page is short enough to be a single band, so
  // there is nothing here for culling to remove.
  //
  // Not `walked <= total`: a band opens by restating the paint state in force
  // where it starts, so the commands actually walked are the page's plus up to
  // a `setColor` and a `setDash` per band drawn. The bound below is what that
  // makes true, and it still catches a walk that has run away.
  const walked = Number(await page.locator("body").getAttribute("data-walked-commands"));
  const total = Number(await page.locator("body").getAttribute("data-total-commands"));
  const bands = Number(await page.locator("body").getAttribute("data-band-count"));
  expect(walked).toBeGreaterThan(0);
  expect(walked).toBeLessThanOrEqual(total + 2 * bands);
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

/**
 * Compares the canvas BITMAP, not a screenshot of the element.
 *
 * An element screenshot is rasterized at the element's position on the page, so
 * anything that moves it by a fraction of a device pixel — a control added to
 * the toolbar above — re-antialiases every glyph and fails the comparison
 * without a single drawing command having changed. That happened twice while
 * the playback UI was being built, and each time the "fix" was to re-bless the
 * baseline, which is how a rendering guard quietly stops guarding.
 *
 * `toDataURL` reads the backing store instead. It is what `drawPage` actually
 * produced, and it is independent of where the canvas sits.
 */
test("engraves the fixture the same way as last time", async ({ page }) => {
  await page.evaluate((url) => window.renderScoreFromURL(url), FIXTURE);
  await expect(page.locator("body")).toHaveAttribute("data-page-count", /[1-9]/);
  // Fonts are registered before the engine reports ready, but Chromium can
  // still be rasterizing the first glyph run when the canvas is filled.
  await page.evaluate(() => document.fonts.ready);

  const dataURL = await page.evaluate(
    () => (document.querySelector("canvas") as HTMLCanvasElement).toDataURL("image/png"),
  );
  const png = Buffer.from(dataURL.slice("data:image/png;base64,".length), "base64");
  // Still an image comparison, so the config's maxDiffPixelRatio still absorbs
  // the antialiasing differences between macOS versions.
  expect(png).toMatchSnapshot("first-page.png");
});

/** A score long enough that the viewer cannot hold all of it mounted. */
const TALL_FIXTURE = "/Web/sheet-music-web/test/fixtures/tall.mscz";

async function scrollToFraction(page: import("@playwright/test").Page, fraction: number) {
  await page.evaluate((f) => {
    const host = document.querySelector("#pages")!;
    host.scrollTop = (host.scrollHeight - host.clientHeight) * f;
    host.dispatchEvent(new Event("scroll"));
  }, fraction);
  await page.waitForTimeout(120);
}

/**
 * The claim this viewer exists to make: what it keeps rasterized is bounded by
 * the viewport, not by the score.
 *
 * Measured before virtualization, the demo held 80.4 MB of canvas for this
 * fixture and 151.8 MB for a 149-part score — linear in length, unbounded. The
 * bound here is deliberately loose: the exact count moves with tile height and
 * the hysteresis margin, and pinning it exactly would fail on a tuning change
 * that broke nothing. What it will not survive is a return to mounting
 * everything, which puts this in the dozens for a document this long.
 */
test("keeps only a viewport's worth of tiles mounted", async ({ page }) => {
  await page.evaluate((url) => window.renderScoreFromURL(url), TALL_FIXTURE);
  await expect(page.locator("body")).toHaveAttribute("data-mounted-tiles", /[1-9]/);

  for (const fraction of [0, 0.25, 0.5, 0.9]) {
    await scrollToFraction(page, fraction);
    const mounted = Number(await page.locator("body").getAttribute("data-mounted-tiles"));
    expect(mounted, `mounted tiles at ${fraction * 100}%`).toBeGreaterThan(0);
    expect(mounted, `mounted tiles at ${fraction * 100}%`).toBeLessThanOrEqual(8);
  }
});

/**
 * Scrolled into the middle of a long score, there has to be ink under the
 * viewport. Catches the mount window being computed in the wrong space — an
 * off-by-a-scroll-offset leaves the visible region unmounted while the counts
 * above still look healthy.
 */
test("still has ink under the viewport after scrolling", async ({ page }) => {
  await page.evaluate((url) => window.renderScoreFromURL(url), TALL_FIXTURE);
  await page.evaluate(() => document.fonts.ready);
  await scrollToFraction(page, 0.5);

  const inked = await page.evaluate(() => {
    const host = document.querySelector("#pages")!;
    const hostBox = host.getBoundingClientRect();
    let count = 0;
    for (const element of document.querySelectorAll("#tile-layer canvas")) {
      const canvas = element as HTMLCanvasElement;
      const box = canvas.getBoundingClientRect();
      if (box.bottom < hostBox.top || box.top > hostBox.bottom) continue;
      const ctx = canvas.getContext("2d")!;
      const { data } = ctx.getImageData(0, 0, canvas.width, canvas.height);
      for (let i = 0; i < data.length; i += 4) {
        if (data[i + 3]! > 128 && data[i]! < 200) count += 1;
      }
    }
    return count;
  });
  expect(inked).toBeGreaterThan(1000);
});

/**
 * Zoom re-rasterizes, so every canvas is discarded and rebuilt at the new
 * scale. The document position under the top of the viewport has to survive
 * that: without an anchor the view lands wherever the new scroll height happens
 * to put it, which is the first thing a zoom UI gets wrong and the last thing
 * anyone notices, because nothing errors.
 */
test("zoom keeps the same music under the top of the viewport", async ({ page }) => {
  await page.evaluate((url) => window.renderScoreFromURL(url), TALL_FIXTURE);
  await scrollToFraction(page, 0.5);
  const before = Number(await page.locator("body").getAttribute("data-scroll-top-mm"));
  expect(before).toBeGreaterThan(0);

  await page.locator("#zoom").fill("2");
  await page.locator("#zoom").dispatchEvent("change");
  await page.waitForTimeout(200);

  const scale = Number(await page.locator("body").getAttribute("data-px-per-mm"));
  const after = Number(await page.locator("body").getAttribute("data-scroll-top-mm"));
  // The scale really changed, so this is not passing by doing nothing.
  expect(scale).toBeGreaterThan(0);
  // Within a tile of where it was. Exact equality would be hostage to
  // sub-pixel rounding in the scroll position.
  expect(Math.abs(after - before)).toBeLessThan(140);
});
