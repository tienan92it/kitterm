import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { defineConfig, type Plugin } from "vite";

import { isPrecompressible } from "./src/precompress";

/**
 * Write a `.br` and a `.gz` beside each text asset of the finished bundle.
 *
 * The daemon does not compress: it sends the sibling when the request's
 * `Accept-Encoding` allows it (`StaticFileServer`, `serveStatic`). The walk
 * covers the whole `outDir`, so the files copied from `public/` (`sw.js`,
 * the manifest, `icon.svg`) get siblings too. `node:zlib` only: no new
 * dependency.
 */
function precompress(): Plugin {
  let outDir = "dist";
  return {
    name: "kitterm-precompress",
    apply: "build",
    configResolved(config) {
      outDir = resolve(config.root, config.build.outDir);
    },
    closeBundle() {
      for (const entry of readdirSync(outDir, { recursive: true, withFileTypes: true })) {
        if (!entry.isFile() || !isPrecompressible(entry.name)) continue;
        const file = join(entry.parentPath, entry.name);
        const bytes = readFileSync(file);
        writeFileSync(
          `${file}.br`,
          brotliCompressSync(bytes, {
            params: {
              [constants.BROTLI_PARAM_QUALITY]: constants.BROTLI_MAX_QUALITY,
              [constants.BROTLI_PARAM_SIZE_HINT]: bytes.length,
            },
          }),
        );
        writeFileSync(`${file}.gz`, gzipSync(bytes, { level: constants.Z_BEST_COMPRESSION }));
      }
    },
  };
}

export default defineConfig({
  base: "/",
  plugins: [precompress()],
  server: {
    port: 5173,
    proxy: {
      "/ws": {
        target: "ws://127.0.0.1:3418",
        ws: true,
      },
      "/api": {
        target: "http://127.0.0.1:3418",
      },
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: true,
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        sessions: resolve(__dirname, "sessions.html"),
        md: resolve(__dirname, "md.html"),
        edit: resolve(__dirname, "edit.html"),
      },
    },
  },
});
