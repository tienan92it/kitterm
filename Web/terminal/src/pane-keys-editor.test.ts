import { describe, expect, it } from "vitest";

import { introSections } from "./intro";
import { matchPaneCommand, type ChordEvent } from "./pane-keys";

const chord = (event: Partial<ChordEvent>): ChordEvent => ({
  key: "",
  metaKey: false,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  ...event,
});

describe("the editor layout chord", () => {
  it("is ⌘⌥E on macOS, by the physical key, so Option's composed character does not hide it", () => {
    expect(matchPaneCommand(chord({ key: "´", code: "KeyE", metaKey: true, altKey: true }), true)).toEqual({
      type: "editor-layout",
    });
    expect(matchPaneCommand(chord({ key: "e", metaKey: true, altKey: true }), true)).toEqual({
      type: "editor-layout",
    });
  });

  it("is Ctrl+Shift+Alt+E elsewhere, leaving Ctrl+Shift+E to the split", () => {
    expect(
      matchPaneCommand(chord({ key: "E", ctrlKey: true, shiftKey: true, altKey: true }), false),
    ).toEqual({ type: "editor-layout" });
    expect(matchPaneCommand(chord({ key: "E", ctrlKey: true, shiftKey: true }), false)).toEqual({
      type: "split",
      dir: "column",
    });
  });

  it("never matches a chord the shell can receive", () => {
    expect(matchPaneCommand(chord({ key: "e", altKey: true }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "e", ctrlKey: true }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "e", metaKey: true }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "e", ctrlKey: true, altKey: true }), false)).toBeNull();
  });
});

describe("the card advertises the editor chord it binds", () => {
  const keys = (isMac: boolean) =>
    introSections(isMac, false)
      .flatMap((section) => section.rows)
      .map((row) => row.keys);

  it("lists ⌘⌥E on macOS and Ctrl+Shift+Alt+E elsewhere", () => {
    expect(keys(true)).toContain("⌘⌥E");
    expect(keys(false)).toContain("Ctrl+Shift+Alt+E");
  });

  it("tells a desktop how to open a path in the editor, and touch where the control is", () => {
    expect(keys(true)).toContain("⌘-click a path");
    expect(keys(false)).toContain("Ctrl-click a path");
    const touch = introSections(true, true).flatMap((section) => section.rows);
    expect(touch.some((row) => row.what.includes("open in editor"))).toBe(true);
    expect(touch.some((row) => row.keys.includes("⌘"))).toBe(false);
  });
});
