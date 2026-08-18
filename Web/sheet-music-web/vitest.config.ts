import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // The bridge tests instantiate the wasm module through PackageToJS's Node
    // bundle, which wants real `node:fs` — not a DOM shim.
    environment: "node",
  },
});
