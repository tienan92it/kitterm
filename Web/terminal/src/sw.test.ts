import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

/**
 * The service worker, run as the file the daemon serves. `public/sw.js` is
 * plain JS with no exports, so the test evaluates it against a fake `self`
 * and drives the three events the way a browser does. What it pins: a push
 * from the daemon becomes one notification with the daemon's title and body,
 * tagged by session; a tap opens `/?session=<id>` on this origin, focusing a
 * window already there and opening one otherwise; and the fetch handler
 * leaves the API and the WebSocket alone.
 */
const SOURCE = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");
const ORIGIN = "https://box.tailnet.ts.net";

type Listener = (event: unknown) => void;
type Shown = { title: string; options: Record<string, unknown> };
type Client = { url: string; focused: boolean; focus: () => Promise<Client> };

type Fake = {
  listeners: Map<string, Listener>;
  shown: Shown[];
  opened: string[];
  windows: Client[];
  self: Record<string, unknown>;
};

function fake(): Fake {
  const listeners = new Map<string, Listener>();
  const shown: Shown[] = [];
  const opened: string[] = [];
  const windows: Client[] = [];
  const self = {
    location: { origin: ORIGIN },
    addEventListener: (type: string, fn: Listener) => listeners.set(type, fn),
    registration: {
      showNotification: (title: string, options: Record<string, unknown>) => {
        shown.push({ title, options });
        return Promise.resolve();
      },
    },
    clients: {
      matchAll: () => Promise.resolve(windows),
      openWindow: (url: string) => {
        opened.push(url);
        return Promise.resolve(null);
      },
    },
  };
  new Function("self", SOURCE)(self);
  return { listeners, shown, opened, windows, self };
}

function windowAt(url: string): Client {
  const client: Client = {
    url,
    focused: false,
    focus: () => {
      client.focused = true;
      return Promise.resolve(client);
    },
  };
  return client;
}

/** The daemon's payload for one session, as `PushNotifier.payload` composes it. */
const payload = {
  session: "5B1C0B0E-5B7A-4C6A-9E8C-3D2F1A0B9C8D",
  state: "needs-input",
  name: "alpha",
  project: "kitterm",
  title: "alpha needs input",
  body: "kitterm · Claude needs your permission",
  url: "/?session=5B1C0B0E-5B7A-4C6A-9E8C-3D2F1A0B9C8D",
  at: 1757574000000,
};

async function push(f: Fake, data: unknown): Promise<void> {
  let settled: Promise<unknown> = Promise.resolve();
  f.listeners.get("push")!({
    data: data === null ? null : { json: () => data },
    waitUntil: (p: Promise<unknown>) => {
      settled = p;
    },
  });
  await settled;
}

async function click(f: Fake, data: unknown): Promise<{ closed: boolean }> {
  const state = { closed: false };
  let settled: Promise<unknown> = Promise.resolve();
  f.listeners.get("notificationclick")!({
    notification: { data, close: () => (state.closed = true) },
    waitUntil: (p: Promise<unknown>) => {
      settled = p;
    },
  });
  await settled;
  return state;
}

describe("sw.js", () => {
  it("registers the three handlers", () => {
    const f = fake();
    expect([...f.listeners.keys()].sort()).toEqual(["fetch", "notificationclick", "push"]);
  });

  it("shows the daemon's title and body, tagged by session, with the pane's URL", async () => {
    const f = fake();
    await push(f, payload);
    expect(f.shown).toHaveLength(1);
    expect(f.shown[0].title).toBe("alpha needs input");
    expect(f.shown[0].options).toMatchObject({
      body: "kitterm · Claude needs your permission",
      tag: "session:5B1C0B0E-5B7A-4C6A-9E8C-3D2F1A0B9C8D",
      renotify: true,
      data: { url: "/?session=5B1C0B0E-5B7A-4C6A-9E8C-3D2F1A0B9C8D" },
    });
  });

  it("shows something for a push with no body, rather than nothing", async () => {
    const f = fake();
    await push(f, null);
    expect(f.shown).toHaveLength(1);
    expect(f.shown[0].title).toBe("kitterm");
    expect(f.shown[0].options).toMatchObject({ data: { url: "/sessions" } });
    expect(f.shown[0].options).not.toHaveProperty("tag");
  });

  it("opens the session's pane on this origin when no window shows it", async () => {
    const f = fake();
    const state = await click(f, { url: payload.url });
    expect(state.closed).toBe(true);
    expect(f.opened).toEqual([`${ORIGIN}/?session=5B1C0B0E-5B7A-4C6A-9E8C-3D2F1A0B9C8D`]);
  });

  it("focuses the window already at that pane instead of opening another", async () => {
    const f = fake();
    const pane = windowAt(`${ORIGIN}/?session=5B1C0B0E-5B7A-4C6A-9E8C-3D2F1A0B9C8D`);
    f.windows.push(windowAt(`${ORIGIN}/sessions`), pane);
    await click(f, { url: payload.url });
    expect(pane.focused).toBe(true);
    expect(f.opened).toEqual([]);
  });

  it("opens the fleet view for a payload with no url, and never another origin", async () => {
    const f = fake();
    await click(f, null);
    await click(f, { url: "https://evil.example/steal" });
    await click(f, { url: "//evil.example/steal" });
    expect(f.opened).toEqual([`${ORIGIN}/sessions`, `${ORIGIN}/sessions`, `${ORIGIN}/sessions`]);
  });

  it("leaves the API and the WebSocket to the network", () => {
    const f = fake();
    const fetch = f.listeners.get("fetch")!;
    for (const path of ["/ws", "/api/sessions", "/api/push/vapid", "/sessions", "/sw.js"]) {
      let responded = false;
      fetch({ request: { url: `${ORIGIN}${path}` }, respondWith: () => (responded = true) });
      expect(responded, path).toBe(false);
    }
  });
});
