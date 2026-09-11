/* kitterm service worker.
 *
 * Served at /sw.js from the web root, so its scope is "/" and it controls both
 * the terminal page and /sessions. It does two things: it stays out of the
 * daemon's API and WebSocket, and it turns a Web Push message from the daemon
 * into a notification that opens the session's pane.
 *
 * Plain JS, no build step and no imports: a worker registered without
 * `type: "module"` cannot import, and a hashed bundle name would change the
 * script URL on every build. `sw.test.ts` runs this file in a fake `self`.
 */
const BYPASS_PREFIXES = ["/ws", "/api/"];

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (BYPASS_PREFIXES.some((p) => url.pathname === p || url.pathname.startsWith(p))) {
    return;
  }
  // Network-only for static assets; no offline cache in MVP.
});

/** The page a notification opens when its payload names none. */
const FALLBACK_URL = "/sessions";

/**
 * The notification for one push payload from the daemon (`PushNotifier.payload`):
 * `title` and `body` are composed there and shown as they are; `url` is the pane
 * to open; `session` tags the notification, so a second message about the same
 * session (needs-input, then failed) replaces the first rather than stacking
 * under it. A body that is not the daemon's JSON still shows something, because
 * a subscription made with `userVisibleOnly` owes the browser a notification
 * for every push, and a silent one makes Chrome show its own generic line.
 */
function notificationFor(payload) {
  const item = payload && typeof payload === "object" ? payload : {};
  const title = typeof item.title === "string" && item.title ? item.title : "kitterm";
  const url = typeof item.url === "string" && item.url ? item.url : FALLBACK_URL;
  const options = {
    body: typeof item.body === "string" ? item.body : "",
    data: { url },
    icon: "/icon-192.png",
    badge: "/icon-192.png",
  };
  if (typeof item.session === "string" && item.session) {
    options.tag = "session:" + item.session;
    options.renotify = true;
  }
  return { title, options };
}

self.addEventListener("push", (event) => {
  let payload = null;
  try {
    payload = event.data ? event.data.json() : null;
  } catch {
    payload = null;
  }
  const { title, options } = notificationFor(payload);
  event.waitUntil(self.registration.showNotification(title, options));
});

/**
 * Open the pane the notification names. A window already at that URL is
 * focused; otherwise a new one opens, which is what happens when the page is
 * closed and the phone is in a pocket. The URL must be on this origin; any
 * other, or none, opens the fleet view instead.
 */
function targetUrl(wanted, origin) {
  let parsed;
  try {
    parsed = new URL(wanted || FALLBACK_URL, origin);
  } catch {
    return new URL(FALLBACK_URL, origin).href;
  }
  return parsed.origin === origin ? parsed.href : new URL(FALLBACK_URL, origin).href;
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = event.notification.data;
  const url = targetUrl(data && typeof data.url === "string" ? data.url : "", self.location.origin);
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      const open = windows.find((client) => client.url === url);
      if (open) return open.focus();
      return self.clients.openWindow(url);
    }),
  );
});
