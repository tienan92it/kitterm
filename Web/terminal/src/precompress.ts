/**
 * Which files of the bundle get a `.br` and a `.gz` sibling.
 *
 * The `precompress` plugin in `vite.config.ts` asks this at the end of a
 * build, and the daemon serves the sibling when `Accept-Encoding` allows it.
 * The list is the same as `StaticFileServer.isCompressible` in the daemon:
 * change the two together. A source map is JSON by content, but only
 * devtools ask for it, so it gets no sibling; an image is compressed already.
 */
const PRECOMPRESSED = new Set(["js", "mjs", "css", "html", "svg", "json", "webmanifest"]);

export function isPrecompressible(name: string): boolean {
  const lower = name.toLowerCase();
  if (lower.endsWith(".map")) return false;
  const dot = lower.lastIndexOf(".");
  return dot > 0 && PRECOMPRESSED.has(lower.slice(dot + 1));
}
