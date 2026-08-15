import { describe, expect, it } from "vitest";

// `?raw` rather than `node:fs`: the project carries no node types, and
// `pnpm build` runs `tsc --noEmit` before vite, so a `node:fs` import fails the
// build. Vite resolves these at transform time and `vite/client` types them.
import indexHtml from "../index.html?raw";
import sessionsHtml from "../sessions.html?raw";

/**
 * Facts about the HTML head that nothing else checks.
 *
 * Vite copies these files through without reading the tags, and no runtime code
 * asserts them, so a later edit can drop one and every build still passes. Both
 * rules below cost a 404 or a 403 on a real device when they break, and neither
 * shows up on a loopback origin.
 */
const PAGES: Array<[name: string, html: string]> = [
  ["index.html", indexHtml],
  ["sessions.html", sessionsHtml],
];

/**
 * A manifest is fetched with credentials mode "omit" by default. The daemon
 * gates every route on a token, so it answers 403 and Add to Home Screen fails
 * on every LAN, Tailscale and proxied origin. Scripts and styles do not show
 * the fault, because they already send the cookie.
 */
describe.each(PAGES)("%s manifest link", (_name, html) => {
  it("asks for credentials", () => {
    const link = html.match(/<link[^>]*rel="manifest"[^>]*>/);
    expect(link).not.toBeNull();
    expect(link![0]).toContain('crossorigin="use-credentials"');
  });

  it("points at the manifest the daemon serves", () => {
    expect(html).toContain('href="/manifest.webmanifest"');
  });
});

/**
 * A page with no icon link makes the browser ask for `/favicon.ico`. The daemon
 * serves no such file and answers 404.
 *
 * Only the sessions page needs the tag. The terminal page draws its favicon
 * from a canvas in `favicon.ts`, which inserts the link itself and would
 * overwrite a static one — including its `type`, leaving the tag describing a
 * format it no longer holds.
 */
describe("favicon", () => {
  it("is declared on the sessions page, which draws none at runtime", () => {
    const link = sessionsHtml.match(/<link[^>]*rel="icon"[^>]*>/);
    expect(link).not.toBeNull();
    expect(link![0]).toContain('href="/icon.svg"');
  });

  it("is left to favicon.ts on the terminal page", () => {
    expect(indexHtml).not.toMatch(/<link[^>]*rel="icon"/);
  });
});
