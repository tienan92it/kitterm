import { describe, expect, it } from "vitest";

import {
  applicationServerKey,
  PUSH_LABEL,
  pushToggle,
  sameServerKey,
  type PushFacts,
} from "./sessions-model";

const ready: PushFacts = {
  watchOnly: false,
  support: "ok",
  permission: "default",
  subscribed: false,
  busy: false,
  error: null,
};

const facts = (extra: Partial<PushFacts>): PushFacts => ({ ...ready, ...extra });

describe("pushToggle", () => {
  it("is hidden for a watch client, whatever else is true", () => {
    expect(pushToggle(facts({ watchOnly: true }))).toBeNull();
    expect(pushToggle(facts({ watchOnly: true, permission: "granted", subscribed: true }))).toBeNull();
  });

  it("offers an unchecked, enabled switch before the browser has been asked", () => {
    expect(pushToggle(ready)).toEqual({
      label: PUSH_LABEL,
      checked: false,
      enabled: true,
      detail: null,
      key: "push",
    });
  });

  it("offers an unchecked switch when permission is granted but nothing is subscribed", () => {
    const toggle = pushToggle(facts({ permission: "granted" }));
    expect(toggle).toMatchObject({ checked: false, enabled: true, detail: null });
  });

  it("is checked once the daemon holds the subscription", () => {
    const toggle = pushToggle(facts({ permission: "granted", subscribed: true }));
    expect(toggle).toMatchObject({ checked: true, enabled: true, detail: null, label: PUSH_LABEL });
  });

  /** The browser asks once. After `denied` the page cannot ask again, so the
   * switch must say where the answer lives rather than sit there dead. */
  it("says that denied is the browser's decision and where to undo it", () => {
    const toggle = pushToggle(facts({ permission: "denied" }));
    expect(toggle).toMatchObject({ checked: false, enabled: false });
    expect(toggle?.detail).toContain("blocked");
    expect(toggle?.detail).toContain("site settings");
  });

  it("says denied even when a stale subscription is still held", () => {
    const toggle = pushToggle(facts({ permission: "denied", subscribed: true }));
    expect(toggle).toMatchObject({ checked: false, enabled: false });
  });

  it("disables the switch and names the reason when the browser has no push", () => {
    const toggle = pushToggle(facts({ support: "unsupported" }));
    expect(toggle).toMatchObject({ checked: false, enabled: false });
    expect(toggle?.detail).toContain("does not support push");
    expect(toggle?.detail).toContain("Home Screen");
  });

  it("disables the switch on an insecure origin and names HTTPS", () => {
    const toggle = pushToggle(facts({ support: "insecure" }));
    expect(toggle).toMatchObject({ checked: false, enabled: false });
    expect(toggle?.detail).toContain("HTTPS");
  });

  it("disables the switch when the daemon has no vapid route", () => {
    const toggle = pushToggle(facts({ support: "old-daemon", permission: "granted" }));
    expect(toggle).toMatchObject({ checked: false, enabled: false });
    expect(toggle?.detail).toContain("daemon");
  });

  it("support beats permission: an unsupported browser never reports denied", () => {
    const toggle = pushToggle(facts({ support: "unsupported", permission: "denied" }));
    expect(toggle?.detail).not.toContain("blocked");
  });

  it("holds the switch at its current position while a change is in flight", () => {
    expect(pushToggle(facts({ busy: true }))).toMatchObject({ checked: false, enabled: false, detail: "Turning on…" });
    expect(pushToggle(facts({ busy: true, subscribed: true, permission: "granted" }))).toMatchObject({
      checked: true,
      enabled: false,
      detail: "Turning off…",
    });
  });

  it("prints the last failure beside an enabled switch, so the reader can try again", () => {
    const toggle = pushToggle(facts({ error: "Could not subscribe: 503" }));
    expect(toggle).toMatchObject({ enabled: true, detail: "Could not subscribe: 503" });
  });

  it("keeps the same label in every state", () => {
    const states: Array<Partial<PushFacts>> = [
      {},
      { permission: "granted", subscribed: true },
      { permission: "denied" },
      { support: "unsupported" },
      { support: "insecure" },
      { support: "old-daemon" },
      { busy: true },
    ];
    for (const state of states) expect(pushToggle(facts(state))?.label).toBe(PUSH_LABEL);
  });

  it("gives the switch one data-focus key that survives every state", () => {
    expect(pushToggle(ready)?.key).toBe("push");
    expect(pushToggle(facts({ permission: "denied" }))?.key).toBe("push");
  });
});

describe("applicationServerKey", () => {
  it("decodes the daemon's base64url key to the bytes pushManager.subscribe takes", () => {
    // 65-byte uncompressed P-256 point: 0x04 then 64 bytes.
    const bytes = new Uint8Array(65);
    bytes[0] = 4;
    for (let i = 1; i < 65; i++) bytes[i] = (i * 37) & 0xff;
    const base64url = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    expect(applicationServerKey(base64url)).toEqual(bytes);
  });

  it("accepts the padded spelling as well", () => {
    expect(applicationServerKey("AQID")).toEqual(new Uint8Array([1, 2, 3]));
    expect(applicationServerKey("AQI=")).toEqual(new Uint8Array([1, 2]));
    expect(applicationServerKey("AQI")).toEqual(new Uint8Array([1, 2]));
  });

  it("restores the two characters base64url renames", () => {
    expect(applicationServerKey("-_8")).toEqual(new Uint8Array([0xfb, 0xff]));
  });
});

describe("sameServerKey", () => {
  const key = new Uint8Array([4, 1, 2, 3]);

  it("is true for the same bytes", () => {
    expect(sameServerKey(new Uint8Array([4, 1, 2, 3]).buffer, key)).toBe(true);
  });

  it("is false for other bytes, another length, or no key at all", () => {
    expect(sameServerKey(new Uint8Array([4, 1, 2, 9]).buffer, key)).toBe(false);
    expect(sameServerKey(new Uint8Array([4, 1, 2]).buffer, key)).toBe(false);
    expect(sameServerKey(null, key)).toBe(false);
    expect(sameServerKey(undefined, key)).toBe(false);
  });
});
