import { describe, expect, it } from "vitest";

import { tagFor } from "./edit-tags";

describe("tagFor", () => {
  it("tags every language of the components table", () => {
    expect(tagFor("a.ts")).toEqual({ text: "ts", className: "edit-tag-name" });
    expect(tagFor("a.tsx")).toEqual({ text: "tsx", className: "edit-tag-name" });
    expect(tagFor("a.js")).toEqual({ text: "js", className: "edit-tag-attr" });
    expect(tagFor("a.mjs")).toEqual({ text: "js", className: "edit-tag-attr" });
    expect(tagFor("a.cjs")).toEqual({ text: "js", className: "edit-tag-attr" });
    expect(tagFor("a.json")).toEqual({ text: "{}", className: "edit-tag-attr" });
    expect(tagFor("a.jsonc")).toEqual({ text: "{}", className: "edit-tag-attr" });
    expect(tagFor("a.md")).toEqual({ text: "md", className: "edit-tag-link" });
    expect(tagFor("a.markdown")).toEqual({ text: "md", className: "edit-tag-link" });
    expect(tagFor("a.swift")).toEqual({ text: "sw", className: "edit-tag-error" });
    expect(tagFor("a.sh")).toEqual({ text: "sh", className: "edit-tag-string" });
    expect(tagFor("a.bash")).toEqual({ text: "sh", className: "edit-tag-string" });
    expect(tagFor("a.zsh")).toEqual({ text: "sh", className: "edit-tag-string" });
    expect(tagFor("a.css")).toEqual({ text: "css", className: "edit-tag-keyword" });
    expect(tagFor("a.html")).toEqual({ text: "htm", className: "edit-tag-error" });
    expect(tagFor("a.htm")).toEqual({ text: "htm", className: "edit-tag-error" });
    expect(tagFor("a.py")).toEqual({ text: "py", className: "edit-tag-number" });
    expect(tagFor("a.go")).toEqual({ text: "go", className: "edit-tag-number" });
    expect(tagFor("a.rs")).toEqual({ text: "rs", className: "edit-tag-attr" });
    expect(tagFor("a.yaml")).toEqual({ text: "yml", className: "edit-tag-keyword" });
    expect(tagFor("a.yml")).toEqual({ text: "yml", className: "edit-tag-keyword" });
    expect(tagFor("a.toml")).toEqual({ text: "tml", className: "edit-tag-number" });
  });

  it("is case-insensitive on the extension", () => {
    expect(tagFor("A.TS")).toEqual({ text: "ts", className: "edit-tag-name" });
  });

  it("carries no tag for an unknown extension, a dotfile, or a name with none", () => {
    expect(tagFor("a.rb")).toBeNull();
    expect(tagFor(".gitignore")).toBeNull();
    expect(tagFor(".env")).toBeNull();
    expect(tagFor("Makefile")).toBeNull();
    expect(tagFor("a.")).toBeNull();
  });
});
