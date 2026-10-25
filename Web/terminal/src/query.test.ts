import { describe, expect, it } from "vitest";
import { queryString } from "./query";

describe("queryString", () => {
  it("encodes a space as %20, never +", () => {
    expect(queryString({ path: "/a b.ts" })).toBe("path=%2Fa%20b.ts");
  });

  it("encodes a literal + as %2B", () => {
    expect(queryString({ path: "a+b" })).toBe("path=a%2Bb");
  });

  it("encodes & and # inside a value", () => {
    expect(queryString({ q: "a&b#c" })).toBe("q=a%26b%23c");
  });

  it("encodes a literal % as %25", () => {
    expect(queryString({ q: "100%" })).toBe("q=100%25");
  });

  it("encodes unicode", () => {
    expect(queryString({ q: "café 🎉" })).toBe("q=caf%C3%A9%20%F0%9F%8E%89");
  });

  it("keeps an empty value as name=", () => {
    expect(queryString({ q: "" })).toBe("q=");
  });

  it("skips a null or undefined value", () => {
    expect(queryString({ a: "1", b: null, c: undefined, d: "2" })).toBe("a=1&d=2");
  });

  it("keeps insertion order for an object", () => {
    expect(queryString({ path: "/x", hidden: "1", session: "S1" })).toBe("path=%2Fx&hidden=1&session=S1");
  });

  it("allows a repeated name from an iterable of pairs", () => {
    expect(
      queryString([
        ["path", "/a"],
        ["path", "/b"],
        ["session", "S1"],
      ]),
    ).toBe("path=%2Fa&path=%2Fb&session=S1");
  });

  it("stringifies a number and a boolean", () => {
    expect(queryString({ staged: true, n: 7 })).toBe("staged=true&n=7");
  });

  it("encodes a name too", () => {
    expect(queryString({ "a b": "1" })).toBe("a%20b=1");
  });
});
