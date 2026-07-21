import { describe, expect, it } from "vitest";

import {
  TAB_TITLE_FALLBACK,
  composeTabTitle,
  cwdFromOsc1337,
  cwdFromOsc7,
  folderFromCwd,
} from "./title";

describe("composeTabTitle", () => {
  it("uses the folder alone by default", () => {
    expect(composeTabTitle({ custom: "", showFolder: true, folder: "kitterm" })).toBe(
      "kitterm",
    );
  });

  it("uses the custom name alone when the folder is off", () => {
    expect(composeTabTitle({ custom: "My App", showFolder: false, folder: "kitterm" })).toBe(
      "My App",
    );
  });

  it("joins custom name and folder when both are on", () => {
    expect(composeTabTitle({ custom: "My App", showFolder: true, folder: "kitterm" })).toBe(
      "My App · kitterm",
    );
  });

  it("falls back when nothing is available", () => {
    expect(composeTabTitle({ custom: "", showFolder: true, folder: null })).toBe(
      TAB_TITLE_FALLBACK,
    );
    expect(composeTabTitle({ custom: "  ", showFolder: false, folder: "x" })).toBe(
      TAB_TITLE_FALLBACK,
    );
  });

  it("trims whitespace from the custom name", () => {
    expect(composeTabTitle({ custom: "  My App  ", showFolder: false, folder: null })).toBe(
      "My App",
    );
  });

  it("omits the folder segment while the folder is unknown", () => {
    expect(composeTabTitle({ custom: "My App", showFolder: true, folder: null })).toBe(
      "My App",
    );
  });
});

describe("folderFromCwd", () => {
  it("returns the last path component", () => {
    expect(folderFromCwd("/Users/antran/Workspace/kitterm")).toBe("kitterm");
  });

  it("tolerates trailing slashes", () => {
    expect(folderFromCwd("/Users/antran/Workspace/kitterm/")).toBe("kitterm");
  });

  it("maps the filesystem root to /", () => {
    expect(folderFromCwd("/")).toBe("/");
  });

  it("returns null for an empty path", () => {
    expect(folderFromCwd("   ")).toBeNull();
  });
});

describe("cwdFromOsc7", () => {
  it("extracts the path from a file URL", () => {
    expect(cwdFromOsc7("file://host/Users/antran/proj")).toBe("/Users/antran/proj");
  });

  it("decodes percent escapes", () => {
    expect(cwdFromOsc7("file://host/Users/antran/my%20proj")).toBe(
      "/Users/antran/my proj",
    );
  });

  it("keeps the raw path when the escape is malformed", () => {
    expect(cwdFromOsc7("file://host/bad%zz")).toBe("/bad%zz");
  });

  it("ignores non file URLs", () => {
    expect(cwdFromOsc7("https://example.com")).toBeNull();
  });
});

describe("cwdFromOsc1337", () => {
  it("reads CurrentDir", () => {
    expect(cwdFromOsc1337("CurrentDir=/Users/antran")).toBe("/Users/antran");
  });

  it("ignores other iTerm2 integration keys", () => {
    expect(cwdFromOsc1337("RemoteHost=antran@GenOS-Pro")).toBeNull();
    expect(cwdFromOsc1337("ShellIntegrationVersion=14;shell=zsh")).toBeNull();
  });

  it("ignores an empty CurrentDir", () => {
    expect(cwdFromOsc1337("CurrentDir=")).toBeNull();
  });
});
