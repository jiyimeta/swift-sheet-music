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
 * Baselines are rasterized by the runner's Chromium and font stack, so they are
 * per-platform. CI runs this job on macOS — the swift.org toolchain installer
 * and `Scripts/swift-org-toolchain.sh` are both macOS-specific — so the
 * `-darwin` snapshots are the committed ones. `maxDiffPixelRatio` leaves room
 * for antialiasing differences between macOS versions without letting a real
 * rendering change through.
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
