import { expect, test } from "@playwright/test";

declare global {
  interface Window {
    renderScoreFromURL(url: string): Promise<void>;
  }
}

const FIXTURE = "/Web/sheet-music-web/test/fixtures/sample.mscz";
const PROBE = {
  xMM: 31.176736111111108,
  yMM: 48.15416666666666,
};

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
  expect(failures).toEqual([]);
});

async function clickScoreAtMM(
  page: import("@playwright/test").Page,
  xMM: number,
  yMM: number,
) {
  await page.evaluate(
    ({ xMM: x, yMM: y }) => {
      const cssPxPerMM = 96 / 25.4;
      const canvases = Array.from(document.querySelectorAll("canvas"));
      for (const canvas of canvases) {
        const box = canvas.getBoundingClientRect();
        const tile = canvas.closest<HTMLElement>(".tile");
        if (tile === null) continue;
        const offset = Number(tile.dataset.offsetMm ?? "0");
        const height = Number(tile.dataset.heightMm ?? "0");
        if (y < offset || y >= offset + height) continue;
        canvas.dispatchEvent(
          new MouseEvent("click", {
            bubbles: true,
            clientX: box.left + x * cssPxPerMM,
            clientY: box.top + (y - offset) * cssPxPerMM,
          }),
        );
        return;
      }
      throw new Error(`no tile contains y=${y}`);
    },
    { xMM, yMM },
  );
}

test("selects with a click, edits, undoes, deletes, and clears selection", async ({
  page,
}) => {
  await expect(page.locator("body")).toHaveAttribute("data-fingerprint", /\d+/);
  const initialFingerprint = await page.locator("body").getAttribute("data-fingerprint");

  await page.locator("#edit-mode").check();
  await expect(page.locator("body")).toHaveAttribute("data-edit-mode", "true");

  await clickScoreAtMM(page, PROBE.xMM, PROBE.yMM);
  await expect(page.locator("body")).toHaveAttribute("data-selected-item", /^note:/);
  await expect(page.locator(".caret")).toHaveCount(1);
  await expect(page.locator(".selection")).toHaveCount(1);
  await expect(page.locator("body")).toHaveAttribute("data-caret-x", /^-?\d/);

  await page.keyboard.press("ArrowUp");
  await expect(page.locator("body")).toHaveAttribute("data-edit-count", "1");
  const editedFingerprint = await page.locator("body").getAttribute("data-fingerprint");
  expect(editedFingerprint).not.toBe(initialFingerprint);
  await expect(page.locator(".caret")).toHaveCount(1);

  await page.keyboard.press("Control+Z");
  await expect(page.locator("body")).toHaveAttribute(
    "data-fingerprint",
    initialFingerprint ?? "",
  );
  await expect(page.locator("body")).toHaveAttribute("data-can-redo", "true");
  const countAfterUndo = Number(
    await page.locator("body").getAttribute("data-edit-count"),
  );

  await clickScoreAtMM(page, PROBE.xMM, PROBE.yMM);
  await page.keyboard.press("Backspace");
  await expect
    .poll(async () =>
      Number(await page.locator("body").getAttribute("data-edit-count")),
    )
    .toBeGreaterThan(countAfterUndo);
  await expect(page.locator("body")).toHaveAttribute("data-edit-refusal", "");

  await clickScoreAtMM(page, 5, 5);
  await expect(page.locator("body")).toHaveAttribute("data-selected-item", "");
  await expect(page.locator(".caret")).toHaveCount(0);
});
