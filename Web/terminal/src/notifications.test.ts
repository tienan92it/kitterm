import { describe, expect, it, vi } from "vitest";

import {
  NotificationCenter,
  Osc99Assembler,
  parseOsc777,
  parseOsc9,
  type NotificationDeps,
} from "./notifications";

describe("parseOsc9", () => {
  it("uses the whole payload as the body", () => {
    expect(parseOsc9("Build finished")).toEqual({ title: null, body: "Build finished" });
  });
  it("ignores an empty payload", () => {
    expect(parseOsc9("   ")).toBeNull();
  });
});

describe("parseOsc777", () => {
  it("parses notify;title;body", () => {
    expect(parseOsc777("notify;Deploy;done in 3s")).toEqual({
      title: "Deploy",
      body: "done in 3s",
    });
  });
  it("keeps semicolons in the body", () => {
    expect(parseOsc777("notify;T;a;b;c")).toEqual({ title: "T", body: "a;b;c" });
  });
  it("treats a title-only sequence as a body", () => {
    expect(parseOsc777("notify;just a message")).toEqual({
      title: null,
      body: "just a message",
    });
  });
  it("ignores non-notify subcommands", () => {
    expect(parseOsc777("precmd;something")).toBeNull();
    expect(parseOsc777("notify;;")).toBeNull();
  });
});

describe("Osc99Assembler", () => {
  it("completes a single-shot notification", () => {
    const a = new Osc99Assembler();
    expect(a.feed(";Hello world")).toEqual({ title: null, body: "Hello world" });
  });

  it("assembles a chunked title + body by id", () => {
    const a = new Osc99Assembler();
    expect(a.feed("i=1:d=0;Agent ")).toBeNull();
    expect(a.feed("i=1:d=0;waiting")).toBeNull();
    expect(a.feed("i=1:p=body:d=1;needs your approval")).toEqual({
      title: "Agent waiting",
      body: "needs your approval",
    });
  });

  it("decodes base64 (utf-8) payloads", () => {
    const a = new Osc99Assembler();
    const utf8 = new TextEncoder().encode("café ready");
    const b64 = btoa(String.fromCharCode(...utf8));
    expect(a.feed(`e=1;${b64}`)).toEqual({ title: null, body: "café ready" });
  });

  it("returns nothing for an empty completed notification", () => {
    const a = new Osc99Assembler();
    expect(a.feed(";")).toBeNull();
  });

  it("ignores non-title/body payload types", () => {
    const a = new Osc99Assembler();
    // An icon chunk must not leak bytes into the title…
    expect(a.feed("i=9:p=icon:d=0;aWNvbmJ5dGVz")).toBeNull();
    expect(a.feed("i=9:d=1;Build done")).toEqual({ title: null, body: "Build done" });
    // …and a notification made only of ignored payloads never fires.
    expect(a.feed("p=icon;ZmFrZQ==")).toBeNull();
  });

  it("completes on a trailing ignored payload chunk", () => {
    const a = new Osc99Assembler();
    expect(a.feed("i=2:d=0;Agent waiting")).toBeNull();
    expect(a.feed("i=2:p=icon:d=1;xxxx")).toEqual({ title: null, body: "Agent waiting" });
  });

  it("caps runaway accumulation into one notification", () => {
    const a = new Osc99Assembler();
    for (let i = 0; i < 100; i++) {
      expect(a.feed(`i=big:d=0;${"x".repeat(1000)}`)).toBeNull();
    }
    const note = a.feed("i=big:d=1;end");
    expect(note).not.toBeNull();
    expect(note?.body.length).toBeLessThanOrEqual(4096);
  });
});

function makeDeps(over: Partial<NotificationDeps> = {}): NotificationDeps & {
  shown: Array<{ title: string; body: string; key?: string }>;
  badge: number[];
} {
  const shown: Array<{ title: string; body: string; key?: string }> = [];
  const badge: number[] = [];
  return {
    shown,
    badge,
    isVisible: () => true,
    focusedSessionId: () => null,
    setBadge: (n) => badge.push(n),
    show: (title, body, _onClick, key) => {
      shown.push({ title, body, key });
      return true;
    },
    focusSession: () => {},
    ...over,
  };
}

describe("NotificationCenter", () => {
  it("suppresses attention for the focused, visible session", () => {
    const deps = makeDeps({ focusedSessionId: () => "s1", isVisible: () => true });
    const c = new NotificationCenter(deps);
    c.raise("s1", { title: null, body: "hi" });
    expect(deps.shown).toHaveLength(0);
    expect(c.waitingCount).toBe(0);
  });

  it("shows and badges a background session", () => {
    const deps = makeDeps({ focusedSessionId: () => "s1" });
    const c = new NotificationCenter(deps);
    c.raise("s2", { title: "Deploy", body: "done" });
    expect(deps.shown).toEqual([{ title: "Deploy", body: "done", key: "s2" }]);
    expect(deps.badge.at(-1)).toBe(1);
  });

  it("still shows when the page is hidden even for the focused session", () => {
    const deps = makeDeps({ focusedSessionId: () => "s1", isVisible: () => false });
    const c = new NotificationCenter(deps);
    c.raise("s1", { title: null, body: "hi" });
    expect(deps.shown).toHaveLength(1);
    expect(c.waitingCount).toBe(1);
  });

  it("counts distinct waiting sessions and clears them", () => {
    const deps = makeDeps({ focusedSessionId: () => null });
    const c = new NotificationCenter(deps);
    c.raise("a", { title: null, body: "1" });
    c.raise("b", { title: null, body: "2" });
    c.raise("a", { title: null, body: "3" }); // repeat: still one waiting 'a'
    expect(c.waitingCount).toBe(2);
    expect(deps.badge.at(-1)).toBe(2);
    c.clear("a");
    expect(c.waitingCount).toBe(1);
    expect(deps.badge.at(-1)).toBe(1);
  });

  it("passes a title-less notification's body as the title", () => {
    const deps = makeDeps({ focusedSessionId: () => null });
    const c = new NotificationCenter(deps);
    c.raise("s", { title: null, body: "just a body" });
    expect(deps.shown[0]).toEqual({ title: "just a body", body: "", key: "s" });
  });

  it("focuses the session when the notification is clicked", () => {
    const focusSession = vi.fn();
    const captured: Array<() => void> = [];
    const deps = makeDeps({
      focusedSessionId: () => null,
      focusSession,
      show: (_t, _b, onClick) => {
        captured.push(onClick);
        return true;
      },
    });
    const c = new NotificationCenter(deps);
    c.raise("s7", { title: "T", body: "B" });
    captured[0]?.();
    expect(focusSession).toHaveBeenCalledWith("s7");
  });
});
