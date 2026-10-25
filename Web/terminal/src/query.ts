/**
 * Query strings the client sends to the daemon.
 *
 * `URLSearchParams`'s own `toString()` form-encodes a space as `+`
 * (`application/x-www-form-urlencoded`). The daemon reads every query with
 * Foundation's `URLComponents.queryItems` (RFC 3986), which keeps a `+` as a
 * literal `+`, so a path with a space in it 404s. `queryString` encodes with
 * `encodeURIComponent` instead, the same escaping the daemon's own `+` rule
 * expects: a space becomes `%20`, and a literal `+` becomes `%2B`.
 */

/** A value this module accepts: skipped when `null` or `undefined`, else
 * stringified. */
export type QueryValue = string | number | boolean | null | undefined;

/** Named values for a query, in insertion order. An object names each key
 * once; an iterable of pairs allows a repeated name (`?path=a&path=b`). */
export type QueryInit = Record<string, QueryValue> | Iterable<readonly [string, QueryValue]>;

/** The query string for `params`, with no leading `?`. Each name and value
 * is `encodeURIComponent`-escaped; a `null` or `undefined` value is skipped,
 * not printed as `name=`. */
export function queryString(params: QueryInit): string {
  const entries: Iterable<readonly [string, QueryValue]> =
    typeof (params as Iterable<unknown>)[Symbol.iterator] === "function"
      ? (params as Iterable<readonly [string, QueryValue]>)
      : Object.entries(params as Record<string, QueryValue>);
  const parts: string[] = [];
  for (const [name, value] of entries) {
    if (value === null || value === undefined) continue;
    parts.push(`${encodeURIComponent(name)}=${encodeURIComponent(String(value))}`);
  }
  return parts.join("&");
}
