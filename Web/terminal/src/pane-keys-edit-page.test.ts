import { describe, expect, it } from "vitest";

import { paneEditUrl } from "./file-preview";
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

// The key that opens `/edit` at the pane's folder (`code-editor` round 7,
// `corpus/04-quick-open.md` item 3): ⌘⇧E on macOS, where the pane binds no
// ⌘⇧ chord but the split and the browsers leave it; Ctrl+Shift+Alt+P
// elsewhere, because Ctrl+Shift+E is the split since the first key table
// and Ctrl+Shift+Alt+E the editor layout.

describe("the edit page chord", () => {
  it("is ⌘⇧E on macOS, by the key and by the physical key", () => {
    expect(matchPaneCommand(chord({ key: "E", metaKey: true, shiftKey: true }), true)).toEqual({ type: "edit-page" });
    expect(matchPaneCommand(chord({ key: "E", code: "KeyE", metaKey: true, shiftKey: true }), true)).toEqual({
      type: "edit-page",
    });
  });

  it("leaves ⌘E, ⌘⌥E and ⌘⇧D to their owners on macOS", () => {
    expect(matchPaneCommand(chord({ key: "e", metaKey: true }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "e", metaKey: true, altKey: true }), true)).toEqual({ type: "editor-layout" });
    expect(matchPaneCommand(chord({ key: "D", metaKey: true, shiftKey: true }), true)).toEqual({
      type: "split",
      dir: "column",
    });
    expect(matchPaneCommand(chord({ key: "E", metaKey: true, shiftKey: true, ctrlKey: true }), true)).toBeNull();
  });

  it("is Ctrl+Shift+Alt+P elsewhere, where Ctrl+Shift+E is the split and Ctrl+Shift+Alt+E the layout", () => {
    expect(matchPaneCommand(chord({ key: "P", ctrlKey: true, shiftKey: true, altKey: true }), false)).toEqual({
      type: "edit-page",
    });
    expect(matchPaneCommand(chord({ key: "E", ctrlKey: true, shiftKey: true }), false)).toEqual({
      type: "split",
      dir: "column",
    });
    expect(matchPaneCommand(chord({ key: "E", ctrlKey: true, shiftKey: true, altKey: true }), false)).toEqual({
      type: "editor-layout",
    });
  });

  it("never matches a chord the shell can receive", () => {
    expect(matchPaneCommand(chord({ key: "E", shiftKey: true }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "E", ctrlKey: true, shiftKey: true }), true)).toBeNull();
    expect(matchPaneCommand(chord({ key: "p", ctrlKey: true }), false)).toBeNull();
    expect(matchPaneCommand(chord({ key: "p", ctrlKey: true, altKey: true }), false)).toBeNull();
    expect(matchPaneCommand(chord({ key: "P", ctrlKey: true, shiftKey: true }), false)).toBeNull();
  });
});

describe("the tab the chord opens", () => {
  it("is /edit at the pane's cwd through its session", () => {
    expect(paneEditUrl("/Users/an/Workspace/kitterm", "A1B2")).toBe("/edit?path=%2FUsers%2Fan%2FWorkspace%2Fkitterm&session=A1B2");
    // A space is %20 and a literal + is %2B — never a bare + for either,
    // which the daemon would read back as a literal + for both.
    expect(paneEditUrl("/tmp/a b+c", "A1B2")).toBe("/edit?path=%2Ftmp%2Fa%20b%2Bc&session=A1B2");
  });

  it("asks the daemon for the session's own cwd before the first cwd frame", () => {
    expect(paneEditUrl(null, "A1B2")).toBe("/edit?path=.&session=A1B2");
    expect(paneEditUrl(null, null)).toBe("/edit?path=.");
  });
});

describe("the card advertises the edit page chord it binds", () => {
  const keys = (isMac: boolean) =>
    introSections(isMac, false)
      .flatMap((section) => section.rows)
      .map((row) => row.keys);

  it("lists ⌘⇧E on macOS and Ctrl+Shift+Alt+P elsewhere, beside the editor layout", () => {
    expect(keys(true)).toContain("⌘⇧E");
    expect(keys(true).indexOf("⌘⇧E")).toBe(keys(true).indexOf("⌘⌥E") + 1);
    expect(keys(false)).toContain("Ctrl+Shift+Alt+P");
    expect(keys(false).indexOf("Ctrl+Shift+Alt+P")).toBe(keys(false).indexOf("Ctrl+Shift+Alt+E") + 1);
    expect(keys(false)).not.toContain("Ctrl+Shift+P");
  });
});
