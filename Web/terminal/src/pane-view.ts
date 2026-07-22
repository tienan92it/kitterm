/**
 * Renders a layout tree as absolutely positioned panes plus draggable splitters.
 *
 * Pane elements are created once per id and only ever restyled — never
 * re-parented — so splitting or closing never moves a live xterm node (which
 * would risk losing its WebGL context and force a full reflow).
 */

import {
  clampRatio,
  computeRects,
  computeSplitters,
  splitBounds,
  type LayoutNode,
  type PaneId,
  type SplitDir,
} from "./pane-layout";

export type LayoutViewCallbacks = {
  /** Live during a drag; the shell restyles without persisting. */
  onRatioPreview: (splitId: string, ratio: number) => void;
  /** Drag finished; safe to persist. */
  onRatioCommit: () => void;
  onClosePane: (pane: PaneId) => void;
};

const pct = (value: number): string => `${(value * 100).toFixed(4)}%`;

export class LayoutView {
  private readonly panes = new Map<PaneId, HTMLElement>();
  private readonly splitters = new Map<string, HTMLElement>();
  private root: LayoutNode | null = null;
  private focused: PaneId | null = null;
  private dragging = false;

  constructor(
    private readonly container: HTMLElement,
    private readonly callbacks: LayoutViewCallbacks,
  ) {
    this.container.classList.add("pane-container");
  }

  /** The element a pane's terminal should be opened into. Created on demand so
   * the shell can construct a `TerminalPane` against it before the first
   * render positions it. */
  paneElement(id: PaneId): HTMLElement {
    const existing = this.panes.get(id);
    if (existing) return existing.querySelector<HTMLElement>(".pane-inner") as HTMLElement;

    const wrapper = document.createElement("div");
    wrapper.className = "pane";
    wrapper.dataset.pane = id;

    const inner = document.createElement("div");
    inner.className = "pane-inner";
    wrapper.appendChild(inner);

    const close = document.createElement("button");
    close.type = "button";
    close.className = "pane-close";
    close.title = "Close pane";
    close.setAttribute("aria-label", "Close pane");
    close.textContent = "✕";
    close.addEventListener("click", (event) => {
      event.stopPropagation();
      this.callbacks.onClosePane(id);
    });
    wrapper.appendChild(close);

    this.container.appendChild(wrapper);
    this.panes.set(id, wrapper);
    return inner;
  }

  removePane(id: PaneId): void {
    this.panes.get(id)?.remove();
    this.panes.delete(id);
  }

  setFocused(id: PaneId | null): void {
    this.focused = id;
    for (const [pane, element] of this.panes) {
      element.classList.toggle("is-focused", pane === id);
    }
  }

  render(root: LayoutNode): void {
    this.root = root;
    const rects = computeRects(root);
    const multi = rects.size > 1;

    for (const [id, rect] of rects) {
      const element = this.panes.get(id);
      if (!element) continue;
      element.style.left = pct(rect.x);
      element.style.top = pct(rect.y);
      element.style.width = pct(rect.w);
      element.style.height = pct(rect.h);
      element.classList.toggle("is-split", multi);
      element.classList.toggle("is-focused", id === this.focused);
    }

    this.renderSplitters(root);
  }

  private renderSplitters(root: LayoutNode): void {
    const wanted = computeSplitters(root);
    const seen = new Set<string>();

    for (const { splitId, dir, rect } of wanted) {
      seen.add(splitId);
      let element = this.splitters.get(splitId);
      if (!element) {
        element = document.createElement("div");
        element.className = "pane-splitter";
        element.dataset.split = splitId;
        this.attachDrag(element, splitId, dir);
        this.container.appendChild(element);
        this.splitters.set(splitId, element);
      }
      element.classList.toggle("is-row", dir === "row");
      element.classList.toggle("is-column", dir === "column");
      if (dir === "row") {
        element.style.left = pct(rect.x);
        element.style.top = pct(rect.y);
        element.style.height = pct(rect.h);
        element.style.width = "";
      } else {
        element.style.left = pct(rect.x);
        element.style.top = pct(rect.y);
        element.style.width = pct(rect.w);
        element.style.height = "";
      }
    }

    for (const [splitId, element] of this.splitters) {
      if (seen.has(splitId)) continue;
      element.remove();
      this.splitters.delete(splitId);
    }
  }

  private attachDrag(element: HTMLElement, splitId: string, dir: SplitDir): void {
    element.addEventListener("pointerdown", (event) => {
      if (!this.root) return;
      const bounds = splitBounds(this.root, splitId);
      if (!bounds) return;

      event.preventDefault();
      element.setPointerCapture(event.pointerId);
      this.dragging = true;
      // Suppress text selection and keep xterm's mouse handling from eating
      // the drag while the pointer travels across panes.
      document.body.classList.add("pane-dragging");

      const box = this.container.getBoundingClientRect();

      const move = (moveEvent: PointerEvent): void => {
        const ratio =
          dir === "row"
            ? (moveEvent.clientX - box.left) / box.width
            : (moveEvent.clientY - box.top) / box.height;
        // Convert the container-relative position into a ratio within this
        // split's own sub-rectangle.
        const local =
          dir === "row"
            ? (ratio - bounds.x) / bounds.w
            : (ratio - bounds.y) / bounds.h;
        this.callbacks.onRatioPreview(splitId, clampRatio(local));
      };

      const up = (upEvent: PointerEvent): void => {
        element.releasePointerCapture(upEvent.pointerId);
        element.removeEventListener("pointermove", move);
        element.removeEventListener("pointerup", up);
        element.removeEventListener("pointercancel", up);
        this.dragging = false;
        document.body.classList.remove("pane-dragging");
        this.callbacks.onRatioCommit();
      };

      element.addEventListener("pointermove", move);
      element.addEventListener("pointerup", up);
      element.addEventListener("pointercancel", up);
    });
  }

  get isDragging(): boolean {
    return this.dragging;
  }

  dispose(): void {
    for (const element of this.panes.values()) element.remove();
    for (const element of this.splitters.values()) element.remove();
    this.panes.clear();
    this.splitters.clear();
  }
}
