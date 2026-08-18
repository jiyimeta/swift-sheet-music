import { defineConfig, devices } from "@playwright/test";

/**
 * Drives Examples/Web in a real Chromium.
 *
 * This is the only layer that sees whether the renderer actually draws. The
 * vitest suite checks that opcodes map to the right Canvas2D calls and the
 * parity suite checks that wasm agrees with the Apple build byte for byte, but
 * neither can catch a shear applied in the wrong direction or a brace positioned
 * off the staff.
 *
 * Baselines are rasterized by the runner's Chromium and font stack, so macOS and
 * Linux disagree on antialiasing. Only the Linux baselines are committed; a
 * local macOS run is informational and its snapshots are gitignored.
 */
export default defineConfig({
  testDir: "./e2e",
  // The page loads a 9 MB wasm module and two fonts before it can draw.
  timeout: 60_000,
  expect: { toHaveScreenshot: { maxDiffPixelRatio: 0.002 } },
  use: {
    ...devices["Desktop Chrome"],
    baseURL: "http://localhost:8080",
  },
  webServer: {
    command: "../../Scripts/web-example-serve.sh 8080",
    url: "http://localhost:8080/Examples/Web/",
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
