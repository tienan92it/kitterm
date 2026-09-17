import { beforeAll, describe, expect, it, vi } from "vitest";

/**
 * The page presents and monitors; it accepts no typed work
 * (`agent-dashboard`, capability 1; `design-foundation.md`, principle 1).
 * The page is rendered by `sessions.ts` itself against a fleet that holds
 * every row the reply control used to attach to: a working agent, an agent
 * waiting for input, and a pending approval. The rendered tree then holds
 * no `input`, no `textarea`, no `contenteditable` and no `[send]`.
 *
 * `sessions.ts` paints through the DOM on import, and the test runner has
 * no DOM package, so the test lends it one: a tree of plain elements that
 * records the tag, the attributes and the children the page gives it, and
 * a `fetch` that answers the daemon's routes from the fixture.
 */

const NOW = 1_758_000_000_000;

/** The foreman at its prompt after a turn: a `Stop` report and `claude` on the tty. */
const foreman = {
  id: "s-foreman",
  name: "foreman",
  cwd: "/Users/antran/Workspace/NgheNhanTrading",
  state: "idle",
  mergedState: "completed",
  marks: 0,
  labels: { crew: "foreman" },
  foregroundProgram: "claude",
  agent: { status: "completed", message: "Round 1 closed", at: NOW - 60_000 },
  orchestrated: true,
};

/** The crew mid-turn: a `PreToolUse` report and `claude` on the tty. */
const crew = {
  ...foreman,
  id: "s-crew",
  name: "symbol-onboarding round 1",
  state: "running",
  mergedState: "working",
  labels: { crew: "symbol-onboarding", goal: "symbol-onboarding", round: "1" },
  agent: { status: "working", message: "Adding the symbol registry route", at: NOW - 5_000 },
};

/** An agent that asked a question and waits at its prompt. */
const waiting = {
  ...foreman,
  id: "s-waiting",
  name: "release notes",
  mergedState: "needs-input",
  agent: { status: "needs-input", message: "Claude needs your input", at: NOW - 120_000 },
};

/** An agent stopped on a tool call until a person answers. */
const blocked = {
  ...foreman,
  id: "s-blocked",
  name: "bench round 2",
  mergedState: "needs-approval",
  pendingApproval: true,
  agent: { status: "working", message: "Running the bench", at: NOW - 10_000 },
};

const approval = {
  id: "a-1",
  tool: "Bash",
  input: JSON.stringify({ command: "swift run KittermBench interactive-echo" }),
  session: "s-blocked",
  waitingMs: 45_000,
};

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [foreman, crew, waiting, blocked] },
  "/api/projects": { projects: [] },
  "/api/approvals": { approvals: [approval] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
};

/** One element of the lent DOM: what the page sets on it and what it holds. */
class FakeElement {
  tagName: string;
  children: Array<FakeElement | string> = [];
  attributes = new Map<string, string>();
  dataset: Record<string, string> = {};
  style = { setProperty(): void {} };
  hidden = false;
  className = "";
  classList = {
    add: (...names: string[]) => {
      const set = new Set(this.className.split(/\s+/).filter(Boolean));
      for (const name of names) set.add(name);
      this.className = [...set].join(" ");
    },
    remove: (...names: string[]) => {
      this.className = this.className
        .split(/\s+/)
        .filter((name) => name && !names.includes(name))
        .join(" ");
    },
    toggle: (name: string, force?: boolean): boolean => {
      const has = this.classList.contains(name);
      const want = force ?? !has;
      if (want) this.classList.add(name);
      else this.classList.remove(name);
      return want;
    },
    contains: (name: string): boolean => this.className.split(/\s+/).includes(name),
  };

  constructor(tagName: string) {
    this.tagName = tagName.toUpperCase();
  }

  get textContent(): string {
    return this.children.map((child) => (typeof child === "string" ? child : child.textContent)).join("");
  }
  set textContent(value: string) {
    this.children = value === "" ? [] : [value];
  }

  append(...nodes: Array<FakeElement | string>): void {
    for (const node of nodes) {
      if (node instanceof FakeElement && node.tagName === "#FRAGMENT") this.children.push(...node.children);
      else this.children.push(node);
    }
  }
  appendChild(node: FakeElement | string): void {
    this.append(node);
  }
  prepend(...nodes: Array<FakeElement | string>): void {
    const rest = this.children;
    this.children = [];
    this.append(...nodes);
    this.children.push(...rest);
  }
  replaceChildren(...nodes: Array<FakeElement | string>): void {
    this.children = [];
    this.append(...nodes);
  }
  remove(): void {}
  setAttribute(name: string, value: string): void {
    this.attributes.set(name, String(value));
  }
  getAttribute(name: string): string | null {
    return this.attributes.get(name) ?? null;
  }
  removeAttribute(name: string): void {
    this.attributes.delete(name);
  }
  hasAttribute(name: string): boolean {
    return this.attributes.has(name);
  }
  addEventListener(): void {}
  removeEventListener(): void {}
  focus(): void {}
  closest(): null {
    return null;
  }
  contains(): boolean {
    return false;
  }

  /** `.class` and `[attr="value"]` selectors, which is all the page asks of its root. */
  querySelector(selector: string): FakeElement | null {
    return this.querySelectorAll(selector)[0] ?? null;
  }
  querySelectorAll(selector: string): FakeElement[] {
    const found: FakeElement[] = [];
    const attr = /^\[([\w-]+)(?:="([^"]*)")?\]$/.exec(selector);
    const matches = (el: FakeElement): boolean => {
      if (selector.startsWith(".")) return el.classList.contains(selector.slice(1));
      if (attr) return attr[2] === undefined ? el.hasAttribute(attr[1]) : el.getAttribute(attr[1]) === attr[2];
      return el.tagName === selector.toUpperCase();
    };
    for (const el of this.descendants()) if (matches(el)) found.push(el);
    return found;
  }
  *descendants(): Generator<FakeElement> {
    for (const child of this.children) {
      if (typeof child === "string") continue;
      yield child;
      yield* child.descendants();
    }
  }
}

const root = new FakeElement("main");
root.setAttribute("id", "sessions");

const fakeDocument = {
  hidden: false,
  title: "",
  activeElement: null,
  body: new FakeElement("body"),
  documentElement: new FakeElement("html"),
  createElement: (tag: string) => new FakeElement(tag),
  createElementNS: (_ns: string, tag: string) => new FakeElement(tag),
  createDocumentFragment: () => new FakeElement("#fragment"),
  getElementById: (id: string) => (id === "sessions" ? root : null),
  querySelector: () => null,
  querySelectorAll: () => [],
  addEventListener(): void {},
};

const storage = new Map<string, string>();

async function settle(): Promise<void> {
  // The page polls after it has read the profiles; each poll awaits five
  // routes and the usage, then paints. Twenty turns of the macrotask
  // queue cover that with room.
  for (let i = 0; i < 20; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
}

beforeAll(async () => {
  vi.stubGlobal("document", fakeDocument);
  vi.stubGlobal("window", globalThis);
  vi.stubGlobal("HTMLElement", FakeElement);
  vi.stubGlobal("Element", FakeElement);
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => void storage.set(key, value),
    removeItem: (key: string) => void storage.delete(key),
  });
  vi.stubGlobal("CSS", { escape: (s: string) => s });
  vi.stubGlobal("isSecureContext", false);
  // The 2 s safety-net poll would outlive the test; one poll is the page.
  vi.stubGlobal("setInterval", () => 0);
  vi.stubGlobal("fetch", async (input: string | URL) => {
    const path = String(input).replace(/\?.*$/, "");
    const body = routes[path];
    if (body === undefined) return new Response("not found", { status: 404 });
    return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
  });
  await import("./sessions");
  await settle();
});

describe("the fleet view takes no typed work", () => {
  it("rendered the fleet it was given: a working agent, one waiting for input, and an approval", () => {
    const text = root.textContent;
    expect(root.querySelectorAll(".row").length + root.querySelectorAll(".strip-item").length).toBeGreaterThanOrEqual(4);
    expect(text).toContain("needs input");
    expect(text).toContain("approve Bash");
    expect(text).toContain("symbol-onboarding round 1");
    expect(root.querySelectorAll("a").map((a) => a.textContent)).toContain("Open the pane");
  });

  it("holds no input, no textarea and no contenteditable", () => {
    const typed = [...root.descendants()]
      .filter(
        (el) =>
          el.tagName === "INPUT" ||
          el.tagName === "TEXTAREA" ||
          el.hasAttribute("contenteditable") ||
          (el as { contentEditable?: string }).contentEditable !== undefined,
      )
      .map((el) => `${el.tagName.toLowerCase()}.${el.className}`);
    expect(typed, "a place to type on a page that only monitors").toEqual([]);
  });

  it("offers no [send], and no reply line under any row or strip item", () => {
    const send = root.querySelectorAll("button").filter((b) => b.textContent.trim() === "send");
    expect(send.map((b) => b.getAttribute("aria-label"))).toEqual([]);
    expect(root.querySelectorAll(".reply")).toEqual([]);
    expect(root.querySelectorAll("form")).toEqual([]);
  });
});
