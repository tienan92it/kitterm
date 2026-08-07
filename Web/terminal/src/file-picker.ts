/**
 * Browsing the machine the session runs on, to hand something its real path.
 *
 * This is the counterpart to dropping a file. A drop has to copy, because a
 * browser never reveals where a dragged file came from — so the agent reads a
 * copy, and editing it leaves the original untouched. Browsing has no such
 * problem: the daemon is already on the machine the files are on, so the path
 * it reports is the one to use, and a folder is just a path like any other.
 *
 * It opens at the cursor and is driven from the keyboard, because it is used
 * mid-sentence — you are typing a prompt to an agent and need a path in the
 * middle of it, so reaching for the mouse breaks the thing you were doing.
 */

export interface FileEntry {
  name: string;
  dir: boolean;
  size?: number;
}

export interface Listing {
  path: string;
  parent?: string;
  entries: FileEntry[];
}

export async function fetchListing(
  path: string | null,
  sessionId: string | null,
  fetchImpl: typeof fetch = fetch,
): Promise<Listing> {
  const params = new URLSearchParams();
  if (path) params.set("path", path);
  if (sessionId) params.set("session", sessionId);
  const response = await fetchImpl(`/api/files?${params.toString()}`);
  if (!response.ok) {
    throw new Error(
      response.status === 403
        ? "This view is watch-only, so files cannot be browsed"
        : "That folder could not be listed",
    );
  }
  const body = (await response.json()) as Listing & { ok?: boolean };
  if (!body.ok) throw new Error("That folder could not be listed");
  return { path: body.path, parent: body.parent, entries: body.entries ?? [] };
}

/** Join a directory and a name without doubling or dropping the separator. */
export function childPath(directory: string, name: string): string {
  return directory.endsWith("/") ? `${directory}${name}` : `${directory}/${name}`;
}

/** A readable size, or nothing for directories. */
export function describeSize(entry: FileEntry): string {
  if (entry.dir || entry.size === undefined) return "";
  const units = ["B", "KB", "MB", "GB"];
  let size = entry.size;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? size : size.toFixed(1)} ${units[unit]}`;
}

/**
 * Keep a selection inside the list, stopping at the ends rather than wrapping —
 * holding an arrow key should come to rest, not cycle forever.
 */
export function clampSelection(index: number, count: number): number {
  if (count <= 0) return 0;
  return Math.min(Math.max(index, 0), count - 1);
}

/** Where the panel goes so it stays inside the pane it belongs to. */
export function placeAtCursor(
  cursor: { left: number; top: number; lineHeight: number },
  panel: { width: number; height: number },
  pane: { width: number; height: number },
  margin = 8,
): { left: number; top: number } {
  const rightmost = Math.max(margin, pane.width - panel.width - margin);
  const left = Math.min(Math.max(cursor.left, margin), rightmost);
  // Below the cursor line by default; above it when there is no room, so the
  // panel never covers the line you are typing on.
  const below = cursor.top + margin;
  const preferred = below + panel.height + margin <= pane.height
    ? below
    : cursor.top - cursor.lineHeight - panel.height - margin;
  // Clamp last, both ways: near the top of a short pane neither placement
  // fits, and an unclamped flip puts the panel off the top edge.
  const lowest = Math.max(margin, pane.height - panel.height - margin);
  const top = Math.min(Math.max(preferred, margin), lowest);
  return { left, top };
}

export interface FilePickerHost {
  sessionId(): string | null;
  /** Called with the chosen paths, already quoted for a shell. */
  insert(paths: readonly string[]): void;
  flash(message: string): void;
  /** Cursor position within the pane, so the panel opens where you are typing. */
  cursorAnchor(): { left: number; top: number; lineHeight: number };
  /** Hand focus back to the terminal when the panel goes away. */
  restoreFocus(): void;
}

/** One navigable line: the parent link, a folder, or a file. */
interface Row {
  label: string;
  path: string;
  isDir: boolean;
  detail: string;
  isParent: boolean;
}

export class FilePicker {
  readonly element: HTMLElement;
  private readonly list: HTMLElement;
  private readonly pathLabel: HTMLElement;
  private current: Listing | null = null;
  private rows: Row[] = [];
  private selected = 0;
  private open = false;
  private readonly onOutsidePointer: (event: Event) => void;

  constructor(private readonly host: FilePickerHost) {
    this.element = document.createElement("div");
    this.element.className = "file-picker";
    this.element.hidden = true;
    this.element.tabIndex = -1;
    this.element.setAttribute("role", "dialog");
    this.element.setAttribute("aria-label", "Choose a file or folder");

    const header = document.createElement("div");
    header.className = "file-picker-header";
    this.pathLabel = document.createElement("div");
    this.pathLabel.className = "file-picker-path";
    const useFolder = document.createElement("button");
    useFolder.type = "button";
    useFolder.className = "file-picker-use";
    useFolder.textContent = "Use folder";
    useFolder.title = "Insert this folder's path (⇧⏎)";
    useFolder.addEventListener("click", () => {
      if (this.current) this.choose(this.current.path);
    });

    const hint = document.createElement("div");
    hint.className = "file-picker-hint";
    hint.textContent = "↑↓ move · → open · ← up · ⏎ insert · ⇧⏎ folder · esc";
    header.append(this.pathLabel, useFolder);

    this.list = document.createElement("div");
    this.list.className = "file-picker-list";
    this.element.append(header, this.list, hint);

    this.element.addEventListener("keydown", (event) => this.onKeyDown(event));
    // Anything outside dismisses. Capture, so a click cannot be swallowed by
    // whatever it lands on before we see it.
    this.onOutsidePointer = (event: Event) => {
      if (!this.element.contains(event.target as Node)) this.hide();
    };
  }

  get isOpen(): boolean {
    return this.open;
  }

  async show(startPath: string | null = null): Promise<void> {
    this.open = true;
    this.element.hidden = false;
    this.selected = 0;
    document.addEventListener("pointerdown", this.onOutsidePointer, true);
    await this.navigate(startPath);
    this.element.focus({ preventScroll: true });
  }

  hide(): void {
    if (!this.open) return;
    this.open = false;
    this.element.hidden = true;
    document.removeEventListener("pointerdown", this.onOutsidePointer, true);
    this.host.restoreFocus();
  }

  private onKeyDown(event: KeyboardEvent): void {
    // Every key here is ours: the panel has focus, so nothing reaches the shell.
    const handled = () => {
      event.preventDefault();
      event.stopPropagation();
    };
    switch (event.key) {
      case "ArrowDown":
        handled();
        this.select(this.selected + 1);
        break;
      case "ArrowUp":
        handled();
        this.select(this.selected - 1);
        break;
      case "ArrowRight": {
        handled();
        const row = this.rows[this.selected];
        if (row?.isDir) void this.navigate(row.path);
        break;
      }
      case "ArrowLeft":
        handled();
        if (this.current?.parent) void this.navigate(this.current.parent);
        break;
      case "Enter": {
        handled();
        // Shift takes the folder you are standing in, which is what an agent
        // usually wants when the answer is "look at this directory".
        if (event.shiftKey) {
          if (this.current) this.choose(this.current.path);
          break;
        }
        const row = this.rows[this.selected];
        if (!row) break;
        // Enter opens a folder, matching ArrowRight; the header button is how
        // you take the folder itself.
        if (row.isDir) void this.navigate(row.path);
        else this.choose(row.path);
        break;
      }
      case "Escape":
        handled();
        this.hide();
        break;
      case "Home":
        handled();
        this.select(0);
        break;
      case "End":
        handled();
        this.select(this.rows.length - 1);
        break;
      default:
        break;
    }
  }

  private select(index: number): void {
    this.selected = clampSelection(index, this.rows.length);
    const children = this.list.children;
    for (let i = 0; i < children.length; i += 1) {
      children[i].classList.toggle("is-selected", i === this.selected);
    }
    (children[this.selected] as HTMLElement | undefined)?.scrollIntoView({ block: "nearest" });
  }

  private async navigate(path: string | null): Promise<void> {
    try {
      this.current = await fetchListing(path, this.host.sessionId());
      this.render();
      this.position();
    } catch (error) {
      this.host.flash(error instanceof Error ? error.message : String(error));
      this.hide();
    }
  }

  private choose(path: string): void {
    this.host.insert([path]);
    this.hide();
  }

  /** Open where the cursor is, clamped to stay inside the pane. */
  private position(): void {
    const pane = this.element.parentElement;
    if (!pane) return;
    const anchor = this.host.cursorAnchor();
    const rect = this.element.getBoundingClientRect();
    const { left, top } = placeAtCursor(
      anchor,
      { width: rect.width, height: rect.height },
      { width: pane.clientWidth, height: pane.clientHeight },
    );
    this.element.style.left = `${left}px`;
    this.element.style.top = `${top}px`;
  }

  private render(): void {
    const listing = this.current;
    if (!listing) return;
    this.pathLabel.textContent = listing.path;
    this.pathLabel.title = listing.path;

    this.rows = [];
    if (listing.parent) {
      this.rows.push({
        label: "..", path: listing.parent, isDir: true, detail: "", isParent: true,
      });
    }
    for (const entry of listing.entries) {
      this.rows.push({
        label: entry.name,
        path: childPath(listing.path, entry.name),
        isDir: entry.dir,
        detail: describeSize(entry),
        isParent: false,
      });
    }

    this.list.replaceChildren();
    if (this.rows.length === 0) {
      const empty = document.createElement("div");
      empty.className = "file-picker-empty";
      empty.textContent = "Nothing here";
      this.list.append(empty);
      return;
    }
    this.rows.forEach((row, index) => this.list.append(this.rowElement(row, index)));
    this.select(0);
  }

  private rowElement(row: Row, index: number): HTMLElement {
    const element = document.createElement("button");
    element.type = "button";
    element.className = row.isDir ? "file-picker-row is-dir" : "file-picker-row";
    const label = document.createElement("span");
    label.className = "file-picker-name";
    label.textContent = row.isParent ? ".." : row.isDir ? `${row.label}/` : row.label;
    const detail = document.createElement("span");
    detail.className = "file-picker-size";
    detail.textContent = row.detail;
    element.append(label, detail);
    element.addEventListener("mouseenter", () => this.select(index));
    element.addEventListener("click", () => {
      if (row.isDir) void this.navigate(row.path);
      else this.choose(row.path);
    });
    return element;
  }
}
