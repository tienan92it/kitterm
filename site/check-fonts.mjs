#!/usr/bin/env node
// Deterministic check for docs/goals/landing-page round 3
// (the-font-is-first-party): the page must load its font from site/
// itself, never from Google's font hosts.
//
// Run: node site/check-fonts.mjs

import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const siteDir = dirname(fileURLToPath(import.meta.url));
const htmlPath = join(siteDir, "index.html");
const html = readFileSync(htmlPath, "utf8");

const failures = [];

for (const host of ["fonts.googleapis.com", "fonts.gstatic.com"]) {
  if (html.includes(host)) {
    failures.push(`index.html references ${host}`);
  }
}

const fontFaceBlocks = html.match(/@font-face\s*{[^}]*}/g) ?? [];
if (fontFaceBlocks.length === 0) {
  failures.push("index.html declares no @font-face rule");
}

const srcPattern = /src:\s*url\(["']?([^"')]+)["']?\)/g;
let sawLocalSrc = false;
for (const block of fontFaceBlocks) {
  for (const match of block.matchAll(srcPattern)) {
    const src = match[1];
    if (/^(https?:)?\/\//.test(src)) {
      failures.push(`@font-face src is remote: ${src}`);
      continue;
    }
    sawLocalSrc = true;
    const filePath = join(siteDir, src);
    if (!existsSync(filePath)) {
      failures.push(`@font-face src file is missing: site/${src}`);
    }
  }
}
if (!sawLocalSrc) {
  failures.push("no @font-face rule has a local src");
}

if (failures.length > 0) {
  console.error("FAIL: fonts are not first-party");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(`PASS: no Google Fonts reference, ${fontFaceBlocks.length} @font-face rule(s), every src file exists`);
