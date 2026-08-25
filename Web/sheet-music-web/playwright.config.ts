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
  // `toMatchSnapshot` because the rendering test compares the canvas backing
  // store rather than a screenshot of the element — see `viewer.spec.ts`. The
  // ratio absorbs antialiasing differences between macOS versions without
  // letting a real change through.
  expect: { toMatchSnapshot: { maxDiffPixelRatio: 0.002 } },
  use: {
    ...devices["Desktop Chrome"],
    // 127.0.0.1 rather than localhost, deliberately. The server is
    // `python3 -m http.server`, which binds IPv4 only; a runner that resolves
    // `localhost` to ::1 first gets connection refused and Playwright simply
    // waits out its readiness timeout, reporting a start-up timeout for a
    // server that started fine.
    baseURL: "http://127.0.0.1:8080",
    launchOptions: {
      // An AudioContext cannot start outside a user gesture, and Playwright's
      // synthesized clicks do not count. This relaxes the policy for the test
      // run only — the engine still builds its context inside a click handler,
      // which is what a real page needs.
      args: ["--autoplay-policy=no-user-gesture-required"],
    },
  },
  webServer: {
    command: "../../Scripts/web-example-serve.sh 8080",
    url: "http://127.0.0.1:8080/Examples/Web/",
    reuseExistingServer: !process.env.CI,
    // Generous because this runs straight after a twenty-minute wasm build on
    // a shared runner, where a cold python3 and a busy filesystem are both
    // plausible. It costs nothing when the server is ready in a second.
    timeout: 120_000,
  },
});
