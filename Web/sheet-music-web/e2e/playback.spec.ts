import { expect, test } from "@playwright/test";

const FIXTURE = "/Web/sheet-music-web/test/fixtures/repeat.mscz";

/**
 * Drives playback in a real Chromium.
 *
 * What this layer adds over `test/engine.test.ts`, which runs the same state
 * machine against a fake transport: that the AudioWorklet actually instantiates,
 * that spessasynth accepts the SMF the bridge rendered, and that its clock
 * advances. None of that can be observed from Node.
 *
 * The audio itself is not asserted — headless Chromium has no way to report what
 * came out of the speakers. What is asserted is the cursor, which moves only if
 * the sequencer's position moves.
 *
 * The SoundFont is generated in the page from `buildClickSoundFont` rather than
 * committed: the score then plays silently (the bank holds two click samples and
 * nothing else), which is all a transport test needs and avoids shipping a
 * General MIDI bank whose redistribution terms would have to be checked.
 */
test.beforeEach(async ({ page }) => {
  const failures: string[] = [];
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") failures.push(message.text());
  });
  await page.goto("/Examples/Web/");
  await expect(page.locator("body")).toHaveAttribute("data-engine-ready", "true");
  await page.evaluate((url) => window.renderScoreFromURL(url), FIXTURE);
  await expect(page.locator("body")).toHaveAttribute("data-page-count", /[1-9]/);
  await page.evaluate(() => window.useGeneratedSoundFont());
  await expect(page.locator("body")).toHaveAttribute("data-soundfont-ready", "true");
  expect(failures).toEqual([]);
});

/** The current cursor position in document millimetres, or `null`. */
async function cursorY(page: import("@playwright/test").Page) {
  const value = await page.evaluate(() => document.body.dataset.cursorY);
  return value === undefined || value === "" ? null : Number(value);
}

test("the play button is disabled until a SoundFont is chosen", async ({ page }) => {
  await page.goto("/Examples/Web/");
  await expect(page.locator("body")).toHaveAttribute("data-engine-ready", "true");
  await expect(page.locator("#play")).toBeDisabled();
});

test("advances the cursor while playing", async ({ page }) => {
  await page.locator("#play").click();
  // Report the reason rather than a bare "stopped ≠ playing": a play that threw
  // leaves the state exactly where a play that never happened would.
  await expect
    .poll(async () => page.evaluate(() => document.body.dataset.playbackError ?? ""))
    .toBe("");
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");

  await expect
    .poll(async () => (await cursorY(page)) !== null, { timeout: 10_000 })
    .toBe(true);
  const first = await cursorY(page);

  // Three measures at ♩=120 in 4/4 with the middle one repeated is eight
  // seconds, so waiting for the cursor to move at all is well inside the piece.
  await expect
    .poll(async () => cursorY(page), { timeout: 10_000 })
    .not.toBe(first);
});

test("pausing freezes the cursor", async ({ page }) => {
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");
  await expect.poll(async () => (await cursorY(page)) !== null, { timeout: 10_000 }).toBe(true);

  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "paused");

  const frozen = await page.evaluate(() => document.body.dataset.cursorMeasure);
  await page.waitForTimeout(600);
  expect(await page.evaluate(() => document.body.dataset.cursorMeasure)).toBe(frozen);
});

test("stopping clears the cursor", async ({ page }) => {
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");
  await expect.poll(async () => (await cursorY(page)) !== null, { timeout: 10_000 }).toBe(true);

  await page.locator("#stop").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "stopped");
  expect(await cursorY(page)).toBeNull();
  await expect(page.locator(".cursor")).toHaveCount(0);
});

test("a one-measure loop keeps the cursor in that measure", async ({ page }) => {
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");
  await page.locator("#loop-from").fill("1");
  await page.locator("#loop-to").fill("1");
  await page.locator("#loop-apply").click();
  await expect(page.locator(".loop-highlight")).not.toHaveCount(0);

  // One measure is two seconds; three seconds of watching covers a wrap and
  // then some. Without the host-driven wrap the cursor would have left it.
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    expect(await page.evaluate(() => document.body.dataset.cursorMeasure)).toBe("0");
    await page.waitForTimeout(150);
  }
});

/**
 * The bug this suite exists for after the fact: every melodic part sounded like
 * a piano, because `renderMidi` strips the tick-0 program and nothing put it
 * back. What can be checked in a browser is that the engine builds a strip per
 * part carrying the score's own patches — the mixer is what asserts them.
 */
test("builds a mixer strip per part, carrying the score's patches", async ({ page }) => {
  await page.evaluate(
    (url) => window.renderScoreFromURL(url),
    "/Web/sheet-music-web/test/fixtures/mixer.mscz",
  );
  await page.evaluate(() => window.useGeneratedSoundFont());
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");
  await expect(page.locator("body")).toHaveAttribute("data-mixer-strip-count", "3");

  await expect(page.locator(".strip .name")).toHaveText(["Bass", "Lead", "Drums"]);

  const values = (selector: string) =>
    page.$$eval(selector, (nodes) =>
      nodes.map((node) => (node as HTMLInputElement).value),
    );
  // Bass is GM 33 (finger bass) and Lead GM 84 (charang); a drum strip has no
  // patch picker at all. Reading 0 here would be the reported bug.
  expect(await values(".strip .patch")).toEqual(["33", "84"]);
  expect(await values(".strip .level")).toEqual(["92", "64", "110"]);

  // The picker shows the engine's own General MIDI table, grouped by family,
  // rather than bare patch numbers or a second transcription of the names.
  const selected = await page.$$eval(".strip .patch", (nodes) =>
    nodes.map((node) => {
      const select = node as HTMLSelectElement;
      return select.options[select.selectedIndex]?.textContent ?? "";
    }),
  );
  expect(selected).toEqual(["33. Electric Bass (finger)", "84. Lead 5 (charang)"]);
  expect(await page.locator(".strip .patch").first().locator("option")).toHaveCount(128);
});

test("the count-in holds the score until the pre-roll ends", async ({ page }) => {
  await page.locator("#countin").check();
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute(
    "data-playback-state",
    "counting-in",
  );
  // It has to get there on its own — the transition is driven by the metronome
  // sequencer's clock, not a timer this test could be racing.
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing", {
    timeout: 10_000,
  });
});
