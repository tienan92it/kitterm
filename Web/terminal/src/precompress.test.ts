import { describe, expect, it } from "vitest";

import { isPrecompressible } from "./precompress";

describe("the files the build compresses", () => {
  it("are the text assets", () => {
    for (const name of [
      "index.html",
      "sw.js",
      "manifest.webmanifest",
      "icon.svg",
      "assets/main-BDCeJSzg.js",
      "assets/main-6GBZ9nXN.css",
      "assets/data-00000000.json",
      "assets/worker-00000000.mjs",
      "assets/UPPER-00000000.JS",
    ]) {
      expect(isPrecompressible(name), name).toBe(true);
    }
  });

  it("are not the source maps, the images, or a sibling", () => {
    for (const name of [
      "assets/main-BDCeJSzg.js.map",
      "assets/main-6GBZ9nXN.css.map",
      "icon-192.png",
      "apple-touch-icon.png",
      "assets/font-00000000.woff2",
      "assets/main-BDCeJSzg.js.br",
      "assets/main-BDCeJSzg.js.gz",
      "LICENSE",
      ".json",
    ]) {
      expect(isPrecompressible(name), name).toBe(false);
    }
  });
});
