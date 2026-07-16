/* kitterm service worker — never intercept daemon API or WebSocket. */
const BYPASS_PREFIXES = ["/ws", "/api/"];

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (BYPASS_PREFIXES.some((p) => url.pathname === p || url.pathname.startsWith(p))) {
    return;
  }
  // Network-only for static assets; no offline cache in MVP.
});
