/**
 * Browsing the machine the session runs on, to hand something its real path.
 *
 * This is the counterpart to dropping a file. A drop has to copy, because a
 * browser never reveals where a dragged file came from — so the agent reads a
 * copy, and editing it leaves the original untouched. Browsing has no such
 * problem: the daemon is already on the machine the files are on, so the path
 * it reports is the one to use, and a folder is just a path like any other.
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

export interface FilePickerHost {
  sessionId(): string | null;
  /** Called with the chosen paths, already quoted for a shell. */
  insert(paths: readonly string[]): void;
  flash(message: string): void;
}

/**
 * A minimal browser: one directory at a time, click a folder to enter it,
 * click a file to take its path. "Use this folder" takes the directory itself,
 * which is what an agent usually wants — a folder is context too.
 */
export class FilePicker {
  readonly element: HTMLElement;
  private readonly list: HTMLElement;
  private readonly pathLabel: HTMLElement;
  private current: Listing | null = null;
  private open = false;

  constructor(private readonly host: FilePickerHost) {
    this.element = document.createElement("div");
    this.element.className = "file-picker";
    this.element.hidden = true;
    this.element.setAttribute("role", "dialog");
    this.element.setAttribute("aria-label", "Choose a file or folder");

    const header = document.createElement("div");
    header.className = "file-picker-header";
    this.pathLabel = document.createElement("div");
    this.pathLabel.className = "file-picker-path";
    header.append(this.pathLabel);

    const useFolder = document.createElement("button");
    useFolder.type = "button";
    useFolder.className = "file-picker-action";
    useFolder.title = "Insert this folder's path";
    useFolder.textContent = "Use folder";
    useFolder.addEventListener("click", () => {
      if (this.current) this.choose(this.current.path);
    });

    const close = document.createElement("button");
    close.type = "button";
    close.className = "file-picker-action";
    close.textContent = "✕";
    close.title = "Close";
    close.setAttribute("aria-label", "Close");
    close.addEventListener("click", () => this.hide());
    header.append(useFolder, close);

    this.list = document.createElement("div");
    this.list.className = "file-picker-list";
    this.element.append(header, this.list);

    this.element.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        this.hide();
      }
    });
  }

  get isOpen(): boolean {
    return this.open;
  }

  async show(startPath: string | null = null): Promise<void> {
    this.open = true;
    this.element.hidden = false;
    await this.navigate(startPath);
  }

  hide(): void {
    this.open = false;
    this.element.hidden = true;
  }

  private async navigate(path: string | null): Promise<void> {
    try {
      this.current = await fetchListing(path, this.host.sessionId());
      this.render();
    } catch (error) {
      this.host.flash(error instanceof Error ? error.message : String(error));
      this.hide();
    }
  }

  private choose(path: string): void {
    this.host.insert([path]);
    this.hide();
  }

  private render(): void {
    const listing = this.current;
    if (!listing) return;
    this.pathLabel.textContent = listing.path;
    this.list.replaceChildren();

    if (listing.parent) {
      this.list.append(this.row("..", true, "", () => void this.navigate(listing.parent!)));
    }
    for (const entry of listing.entries) {
      const full = childPath(listing.path, entry.name);
      this.list.append(
        this.row(entry.name, entry.dir, describeSize(entry), () =>
          entry.dir ? void this.navigate(full) : this.choose(full),
        ),
      );
    }
    if (listing.entries.length === 0 && !listing.parent) {
      const empty = document.createElement("div");
      empty.className = "file-picker-empty";
      empty.textContent = "Nothing here";
      this.list.append(empty);
    }
  }

  private row(name: string, isDir: boolean, detail: string, onPick: () => void): HTMLElement {
    const row = document.createElement("button");
    row.type = "button";
    row.className = isDir ? "file-picker-row is-dir" : "file-picker-row";
    const label = document.createElement("span");
    label.textContent = isDir ? `${name}/` : name;
    const size = document.createElement("span");
    size.className = "file-picker-size";
    size.textContent = detail;
    row.append(label, size);
    row.addEventListener("click", onPick);
    return row;
  }
}
