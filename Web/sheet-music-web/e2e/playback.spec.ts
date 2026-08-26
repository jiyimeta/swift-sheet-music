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

test("clicking the score seeks the cursor there", async ({ page }) => {
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");
  await expect.poll(async () => (await cursorY(page)) !== null, { timeout: 10_000 }).toBe(true);
  await page.locator("#stop").click();
  await page.locator("#play").click();
  await page.locator("#play").click(); // pause, so the cursor stays where it is put

  const canvas = page.locator("canvas").first();
  const box = (await canvas.boundingBox())!;
  // Well into the score horizontally, on the staff — nearest-element resolution
  // means it does not have to land on a notehead.
  await canvas.click({ position: { x: box.width * 0.7, y: box.height * 0.55 } });

  // The cursor has to land there while PAUSED. Setting a sequencer's position
  // is a message to its worklet, so the position it reports back is stale for a
  // buffer or two — drawing the cursor from that reading leaves it where
  // playback was, which is invisible while playing and permanent while paused.
  await expect
    .poll(async () => Number(await page.evaluate(() => document.body.dataset.cursorMeasure)))
    .toBeGreaterThan(0);
});

test("solo silences the other strips, and clearing it restores them", async ({ page }) => {
  await page.evaluate(
    (url) => window.renderScoreFromURL(url),
    "/Web/sheet-music-web/test/fixtures/mixer.mscz",
  );
  await page.evaluate(() => window.useGeneratedSoundFont());
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-mixer-strip-count", "3");
  // Channels 0, 1 and 9 — the drum part is on 9 whatever its position.
  await expect(page.locator("body")).toHaveAttribute("data-audible-strips", "0,1,9");

  await page.locator(".strip .solo").nth(1).check();
  await expect(page.locator("body")).toHaveAttribute("data-audible-strips", "1");

  await page.locator(".strip .solo").nth(1).uncheck();
  await expect(page.locator("body")).toHaveAttribute("data-audible-strips", "0,1,9");
});

test("layers a generated click bank onto the metronome", async ({ page }) => {
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");
  // `false` here would mean the synth host reported no bank layering, which is
  // the only way the click can silently stay on General MIDI's wood blocks.
  await expect(page.locator("body")).toHaveAttribute("data-click-bank", "custom");
});

/**
 * Swap in mixer.mscz, whose drum part hits notes 76 and 77 — the only two the
 * generated click bank defines. Every other fixture would export correct-length
 * silence through that bank, which is indistinguishable from a broken render.
 */
async function useAudibleFixture(page: import("@playwright/test").Page) {
  await page.evaluate(
    (url) => window.renderScoreFromURL(url),
    "/Web/sheet-music-web/test/fixtures/mixer.mscz",
  );
  await page.evaluate(() => window.useGeneratedSoundFont());
}

/**
 * Export in `format` and wait for the page's terminal marker.
 *
 * The marker rather than an empty error string: an export that has not finished
 * yet also has no error, so polling for emptiness passes immediately and the
 * failure then surfaces as a timeout on some later attribute.
 */
async function exportAs(
  page: import("@playwright/test").Page,
  format: string,
  expected: "ok" | "undecodable" = "ok",
) {
  await page.locator("#export-format").selectOption(format);
  await page.locator("#export").click();
  await expect
    .poll(
      async () =>
        page.evaluate(
          () =>
            document.body.dataset.exportDone ??
            document.body.dataset.exportError ??
            "",
        ),
      { timeout: 30_000 },
    )
    .toBe(expected);
}

/** Peak level of the exported file, decoded back through the browser. */
async function exportedPeak(page: import("@playwright/test").Page) {
  return Number(await page.evaluate(() => document.body.dataset.exportedPeak));
}

/**
 * The one thing only a browser can answer about the export: that an
 * `OfflineAudioContext` really does instantiate spessasynth's worklet and render
 * through it. Everything about the bytes themselves is pinned by
 * `test/wav.test.ts`, which needs no browser.
 */
test("renders the score to a WAV faster than real time", async ({ page }) => {
  await useAudibleFixture(page);
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");
  await exportAs(page, "wav");

  const bytes = Number(
    await page.evaluate(() => document.body.dataset.exportedBytes),
  );
  // mixer.mscz is one 4/4 bar at ♩=120 — two seconds — plus a two-second tail;
  // stereo 16-bit at 44.1 kHz is 176,400 B/s.
  expect(bytes).toBeGreaterThan(44 + 3 * 176_400);

  // And it has to contain audio. A misconfigured offline render — the snapshot
  // not applied, the sound bank not transferred, the worklet never reached —
  // yields a buffer of exactly the right length full of silence, which the byte
  // count above cannot tell apart from a good one.
  expect(await exportedPeak(page)).toBeGreaterThan(0.01);
});

/**
 * AIFF is offered, and Chromium will not read it back.
 *
 * `decodeAudioData` takes WAV, MP3, AAC/MP4, Ogg and FLAC — not AIFF, which it
 * rejects with a null error for a file CoreAudio's `afinfo` reads as a clean
 * 2-channel 44.1 kHz big-endian PCM. So the browser adds nothing to what
 * `test/aiff.test.ts` already pins field by field; what it can say is that the
 * format reaches the picker and produces a downloadable file of the right size,
 * and that the page survives a container it cannot decode.
 */
test("offers AIFF, and survives a container Chromium will not decode", async ({ page }) => {
  await useAudibleFixture(page);
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");

  expect(
    (await page.evaluate(() => document.body.dataset.exportFormats ?? "")).split(","),
  ).toContain("aiff");

  await exportAs(page, "aiff", "undecodable");
  expect(await page.evaluate(() => document.body.dataset.exportedType)).toBe("audio/aiff");
  // Uncompressed, like the WAV: one 4/4 bar at ♩=120 plus a two-second tail,
  // stereo 16-bit at 44.1 kHz.
  const bytes = Number(await page.evaluate(() => document.body.dataset.exportedBytes));
  expect(bytes).toBeGreaterThan(54 + 3 * 176_400);
});

/**
 * M4A, decoded back through the browser's own demuxer.
 *
 * `test/mp4.test.ts` walks the box tree, but it walks it with the same
 * understanding that wrote it — only a real demuxer can say whether the result
 * is actually an MP4. And an MP4 has a failure mode WAV does not: without the
 * edit list the encoder's ~2048 frames of priming stay in the presentation,
 * shifting everything ~46 ms later while leaving length and peak plausible.
 */
test("renders the score to an M4A that a decoder accepts", async ({ page }) => {
  await useAudibleFixture(page);
  await page.locator("#play").click();
  await expect(page.locator("body")).toHaveAttribute("data-playback-state", "playing");

  const formats = (
    await page.evaluate(() => document.body.dataset.exportFormats ?? "")
  ).split(",");
  expect(formats).toContain("m4a");
  // Never offered: no browser ships an MP3 encoder, and hiding it beats letting
  // a user pick a format that throws after a full render.
  expect(formats).not.toContain("mp3");

  await exportAs(page, "m4a");

  expect(await page.evaluate(() => document.body.dataset.exportedType)).toBe("audio/mp4");
  // Compressed: the same audio as AAC is a fraction of the WAV above, so a byte
  // count anywhere near 176,400 per second would mean raw PCM got mislabelled.
  const bytes = Number(await page.evaluate(() => document.body.dataset.exportedBytes));
  expect(bytes).toBeGreaterThan(4_000);
  expect(bytes).toBeLessThan(3 * 176_400);

  expect(await exportedPeak(page)).toBeGreaterThan(0.01);

  // The edit list assertion. Much past one AAC frame means the priming was left
  // in the presentation.
  const leadingSilenceMs = Number(
    await page.evaluate(() => document.body.dataset.exportedLeadingSilenceMs),
  );
  expect(leadingSilenceMs).toBeLessThan(23.3);
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
