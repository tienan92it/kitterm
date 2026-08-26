import { describe, expect, it } from "vitest";

import { describePreview, formatBytes, type PreviewMeta } from "./file-preview";

const meta = (over: Partial<PreviewMeta> = {}): PreviewMeta => ({
  kind: "text",
  totalBytes: 1234,
  truncated: false,
  filename: "a.txt",
  ...over,
});

describe("formatBytes", () => {
  it("keeps small files in bytes", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(1023)).toBe("1023 B");
  });

  it("steps up a unit at a time", () => {
    expect(formatBytes(1024)).toBe("1.0 KB");
    expect(formatBytes(1024 * 1024)).toBe("1.0 MB");
    expect(formatBytes(1024 * 1024 * 1024)).toBe("1.0 GB");
  });

  // A decimal is worth having at 1.5 KB and noise at 640 KB.
  it("drops the decimal once the number is large enough to read", () => {
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(1024 * 640)).toBe("640 KB");
  });
});

describe("describePreview", () => {
  it("gives the size for a whole file", () => {
    expect(describePreview(meta({ totalBytes: 2048 }))).toBe("2.0 KB");
  });

  // A log that stops mid-line otherwise reads as a file that ends there.
  it("says so when only part of the file came back", () => {
    expect(describePreview(meta({ totalBytes: 5_000_000, truncated: true })))
      .toBe("4.8 MB · showing the first part");
  });

  it("says a binary has no preview, and still gives its size", () => {
    expect(describePreview(meta({ kind: "binary", totalBytes: 4096 })))
      .toBe("4.0 KB · not previewable");
  });

  // Truncation is beside the point for something that is not rendered at all.
  it("prefers the binary note over the truncation note", () => {
    expect(describePreview(meta({ kind: "binary", totalBytes: 4096, truncated: true })))
      .toBe("4.0 KB · not previewable");
  });
});
