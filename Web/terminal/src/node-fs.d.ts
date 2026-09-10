/**
 * The one `node:fs` function `theme-contrast-derive.ts` uses.
 *
 * The project carries no `@types/node`, and adding the package would touch
 * `package.json` and `pnpm-lock.yaml`. `tsc --noEmit` runs before every build,
 * so the import needs a type. Keep this declaration to what a test actually
 * calls: product code runs in a browser and must never reach for `node:fs`.
 */
declare module "node:fs" {
  export function readFileSync(path: string | URL, encoding: "utf8"): string;
}
