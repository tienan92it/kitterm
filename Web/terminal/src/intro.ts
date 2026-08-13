/**
 * The getting-started card.
 *
 * kitterm has no chrome to explore — a browser tab is a shell and nothing
 * announces the chords that make it a terminal *multiplexer*. This is the one
 * place that says so, shown once per browser and reachable afterwards from
 * settings or ⌘/.
 *
 * It is a card rather than a banner printed into the shell on purpose: the
 * scrollback belongs to the user's work, and an MOTD would reprint on every
 * new pane and compete with whatever agent is running there.
 *
 * The rows are data so a test can hold them against `pane-keys`, which is the
 * actual binding table. A shortcut list that drifts from the bindings is worse
 * than none.
 */

const SEEN_KEY = "kitterm:intro-seen";

export interface IntroRow {
  keys: string;
  what: string;
}

export interface IntroSection {
  title: string;
  rows: IntroRow[];
}

/** True on the first visit of a browser that has never dismissed the card. */
export const shouldShowIntro = (): boolean => {
  try {
    return localStorage.getItem(SEEN_KEY) === null;
  } catch {
    // Private mode: showing it every time would be worse than never.
    return false;
  }
};

export const markIntroSeen = (): void => {
  try {
    localStorage.setItem(SEEN_KEY, "1");
  } catch {
    // Nothing to do — the card is cosmetic.
  }
};

/**
 * What the card lists, for this platform and input.
 *
 * Touch gets gestures instead of chords: a phone has no ⌘, and the extra-keys
 * row is the thing a first-time user most needs pointed out. ⌘W and ⌘T are
 * absent throughout because the browser reserves them and a page cannot take
 * them back — the ⌥ variants are what kitterm actually binds.
 */
export const introSections = (isMac: boolean, touch: boolean): IntroSection[] => {
  if (touch) {
    return [
      {
        title: "Touch",
        rows: [
          { keys: "Long-press", what: "Select text, then copy or paste" },
          { keys: "Swipe", what: "Scroll — or move inside vim, less, htop" },
          { keys: "Drag a file in", what: "Its path lands at your cursor" },
        ],
      },
      {
        title: "On screen",
        rows: [
          { keys: "Key row", what: "Esc, Tab, Ctrl and arrows above the keyboard" },
          { keys: "＋", what: "Attach a file from this device" },
          { keys: "⌸", what: "Browse the machine kitterm runs on" },
          { keys: "⧉", what: "Share the session — others watch it live" },
          { keys: "⚙", what: "Theme, font, tab name" },
        ],
      },
    ];
  }

  const panes: IntroRow[] = isMac
    ? [
        { keys: "⌘D", what: "Split right" },
        { keys: "⌘⇧D", what: "Split down" },
        { keys: "⌘⌥↑ / ⌘⌥↓", what: "Move between panes" },
        { keys: "⌘⌥W", what: "Close this pane" },
        { keys: "⌘⌥T", what: "New tab" },
      ]
    : [
        { keys: "Ctrl+Shift+D", what: "Split right" },
        { keys: "Ctrl+Shift+E", what: "Split down" },
        { keys: "Ctrl+Shift+↑ / ↓", what: "Move between panes" },
        { keys: "Ctrl+Shift+Alt+W", what: "Close this pane" },
        { keys: "Ctrl+Shift+Alt+T", what: "New tab" },
      ];

  const inThePane: IntroRow[] = isMac
    ? [
        { keys: "⌘F", what: "Find in the scrollback" },
        { keys: "⌘↑ / ⌘↓", what: "Jump between prompts" },
        { keys: "⌘C", what: "Copy the selection — Ctrl+C still interrupts" },
        { keys: "⌘⌥O", what: "Browse files on this machine" },
        { keys: "⌘, / ⌘/", what: "Settings, and this card" },
      ]
    : [
        { keys: "Ctrl+Shift+F", what: "Find in the scrollback" },
        { keys: "Ctrl+Shift+C", what: "Copy the selection — Ctrl+C still interrupts" },
        { keys: "Ctrl+Shift+Alt+O", what: "Browse files on this machine" },
        { keys: "Ctrl+, / Ctrl+Shift+/", what: "Settings, and this card" },
      ];

  return [
    { title: "Panes", rows: panes },
    { title: "In a pane", rows: inThePane },
    {
      title: "Anywhere",
      rows: [
        { keys: "Drop a file", what: "Its path lands at your cursor, unrun" },
        { keys: "⧉", what: "Share the session — others watch it live" },
      ],
    },
  ];
};

/** The mark from the app icon, drawn in the current accent so it belongs to
 * whatever terminal theme is loaded. */
const logo = (): SVGSVGElement => {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 512 512");
  svg.setAttribute("class", "intro-logo");
  svg.setAttribute("aria-hidden", "true");

  const group = document.createElementNS("http://www.w3.org/2000/svg", "g");
  group.setAttribute("fill", "none");
  group.setAttribute("stroke", "currentColor");
  group.setAttribute("stroke-width", "42");
  group.setAttribute("stroke-linecap", "round");
  group.setAttribute("stroke-linejoin", "round");

  const chevron = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
  chevron.setAttribute("points", "128,144 224,256 128,368");
  const bar = document.createElementNS("http://www.w3.org/2000/svg", "line");
  bar.setAttribute("x1", "304");
  bar.setAttribute("y1", "152");
  bar.setAttribute("x2", "304");
  bar.setAttribute("y2", "360");

  group.append(chevron, bar);
  svg.append(group);
  return svg;
};

export interface IntroCard {
  close(): void;
}

/**
 * Mount the card in `host`. Dismissing it records that, so the first visit is
 * the only unprompted one however it was opened.
 */
export const showIntro = (
  host: HTMLElement,
  { isMac, touch }: { isMac: boolean; touch: boolean },
): IntroCard => {
  const scrim = document.createElement("div");
  scrim.className = "intro-scrim";

  const card = document.createElement("div");
  card.className = "intro-card";
  card.setAttribute("role", "dialog");
  card.setAttribute("aria-modal", "true");
  card.setAttribute("aria-label", "Getting started with kitterm");

  const header = document.createElement("div");
  header.className = "intro-header";
  const title = document.createElement("h2");
  title.className = "intro-title";
  title.textContent = "kitterm";
  const tagline = document.createElement("p");
  tagline.className = "intro-tagline";
  tagline.textContent = "Your terminal, on whatever device you have.";
  const heading = document.createElement("div");
  heading.append(title, tagline);
  header.append(logo(), heading);

  const body = document.createElement("div");
  body.className = "intro-body";
  for (const section of introSections(isMac, touch)) {
    const group = document.createElement("section");
    group.className = "intro-section";
    const label = document.createElement("h3");
    label.className = "intro-section-title";
    label.textContent = section.title;
    group.append(label);
    const list = document.createElement("dl");
    list.className = "intro-rows";
    for (const row of section.rows) {
      const keys = document.createElement("dt");
      keys.className = "intro-keys";
      keys.textContent = row.keys;
      const what = document.createElement("dd");
      what.className = "intro-what";
      what.textContent = row.what;
      list.append(keys, what);
    }
    group.append(list);
    body.append(group);
  }

  const footer = document.createElement("div");
  footer.className = "intro-footer";
  const hint = document.createElement("span");
  hint.className = "intro-hint";
  hint.textContent = touch ? "Reopen from settings" : isMac ? "Reopen with ⌘/" : "Reopen with Ctrl+Shift+/";
  const dismiss = document.createElement("button");
  dismiss.type = "button";
  dismiss.className = "intro-dismiss";
  dismiss.textContent = "Got it";
  footer.append(hint, dismiss);

  card.replaceChildren(header, body, footer);
  scrim.append(card);
  host.append(scrim);

  let closed = false;
  const close = (): void => {
    if (closed) return;
    closed = true;
    markIntroSeen();
    document.removeEventListener("keydown", onKeydown, true);
    scrim.remove();
  };

  // Capture phase: xterm's own key handling sits below, and Escape here must
  // mean "close the card", not reach the shell.
  function onKeydown(event: KeyboardEvent): void {
    if (event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    close();
  }

  dismiss.addEventListener("click", close);
  scrim.addEventListener("click", (event) => {
    if (event.target === scrim) close();
  });
  document.addEventListener("keydown", onKeydown, true);
  dismiss.focus();

  return { close };
};
