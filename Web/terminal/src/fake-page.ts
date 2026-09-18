import { vi } from "vitest";

/**
 * A DOM for a test of `sessions.ts`, which paints through the DOM on import
 * while the test runner has no DOM package. The page gets a tree of plain
 * elements that records the tag, the attributes and the children it is
 * given, and a `fetch` that answers the daemon's routes from a fixture the
 * test owns and may change between polls. Test-only; nothing ships it.
 */
export class FakeElement {
  tagName: string;
  children: Array<FakeElement | string> = [];
  attributes = new Map<string, string>();
  /** `dataset.needs = "row"` writes `data-needs`, as the DOM does, so an
   * attribute selector finds it. */
  dataset: Record<string, string> = new Proxy({} as Record<string, string>, {
    set: (target, key, value) => {
      target[String(key)] = String(value);
      this.attributes.set(`data-${String(key).replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`, String(value));
      return true;
    },
  });
  style = { setProperty(): void {} };
  hidden = false;
  className = "";
  href = "";
  title = "";
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

  /** `.class`, `[attr]`, `[attr="value"]` and tag selectors, which is all the page asks of its root. */
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

export type FakePage = {
  /** The `#sessions` element the page paints into. */
  root: FakeElement;
  /** The `document` the page sees; `title` is what the page set. */
  document: { title: string };
  /** Let the page's pending work run: a poll awaits five routes and the
   * usage, then paints. Twenty turns of the macrotask queue cover that
   * with room. */
  settle(): Promise<void>;
  /** Run the page's 2 s safety-net poll once, then settle, so a test can
   * change the routes and read the repaint. */
  poll(): Promise<void>;
};

/**
 * Install the lent DOM and the route stub before `sessions.ts` is imported.
 * `routes` maps a path (no query) to the JSON body it answers; a path not
 * in it answers 404. The test keeps the object and may replace its entries
 * between polls.
 */
export function installFakePage(routes: Record<string, unknown>): FakePage {
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
  const polls: Array<() => void> = [];
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
  // The 2 s safety-net poll would outlive the test; keep its callback so a
  // test can run one poll by hand.
  vi.stubGlobal("setInterval", (fn: () => void) => {
    polls.push(fn);
    return 0;
  });
  vi.stubGlobal("fetch", async (input: string | URL) => {
    const path = String(input).replace(/\?.*$/, "");
    const body = routes[path];
    if (body === undefined) return new Response("not found", { status: 404 });
    const json = JSON.stringify(body);
    // The daemon's knowledge route answers an ETag that moves with the
    // package, and the page repaints on it; the stub's moves with the body.
    let hash = 0;
    for (let i = 0; i < json.length; i += 1) hash = (hash * 31 + json.charCodeAt(i)) | 0;
    return new Response(json, { status: 200, headers: { "content-type": "application/json", etag: `"${json.length}-${hash}"` } });
  });
  const settle = async (): Promise<void> => {
    for (let i = 0; i < 40; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  };
  return {
    root,
    document: fakeDocument,
    settle,
    poll: async () => {
      for (const fn of polls) fn();
      await settle();
    },
  };
}
