import { describe, expect, it } from "vitest";
import { PACKAGE_NAME } from "../src/version.js";

describe("package identity", () => {
  it("names itself", () => {
    expect(PACKAGE_NAME).toBe("@jiyimeta/sheet-music-web");
  });
});
