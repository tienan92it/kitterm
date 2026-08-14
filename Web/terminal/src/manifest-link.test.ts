import { describe, expect, it } from "vitest";

// `?raw` rather than `node:fs`: the project carries no node types, and
// `pnpm build` runs `tsc --noEmit` before vite, so a `node:fs` import fails the
// build. Vite resolves these at transform time and `vite/client` types them.
import indexHtml from "../index.html?raw";
import sessionsHtml from "../sessions.html?raw";

/**
 * The manifest link must ask for credentials.
 *
 * A manifest is fetched with credentials mode "omit" by default. The daemon
 * gates every route on a token, so it answers 403 and Add to Home Screen fails
 * on every LAN, Tailscale and proxied origin. Scripts and styles do not show
 * the fault, because they already send the cookie.
 *
 * The attribute lives in HTML that no other test reads, so a later edit can
 * drop it and nothing else complains. This test is the guard.
 */
const PAGES: Array<[name: string, html: string]> = [
  ["index.html", indexHtml],
  ["sessions.html", sessionsHtml],
];

describe.each(PAGES)("%s", (_name, html) => {
  it("asks for credentials on the manifest link", () => {
    const link = html.match(/<link[^>]*rel="manifest"[^>]*>/);
    expect(link).not.toBeNull();
    expect(link![0]).toContain('crossorigin="use-credentials"');
  });

  it("points at the manifest the daemon serves", () => {
    expect(html).toContain('href="/manifest.webmanifest"');
  });
});
