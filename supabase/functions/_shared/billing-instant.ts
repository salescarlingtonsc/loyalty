/* nestly_v767 — one spelling for an instant before it is hashed.

   PostgREST renders a timestamptz as `2027-09-04T16:00:00+00:00`; the provider snapshot builds
   `2027-09-04T16:00:00.000Z` from a Unix epoch. Same instant, different bytes, and the
   reconciliation digest is a hash of bytes — so every subscription and every invoice was being
   reported as a MISMATCH (6 of 6 on the 2026-09-05 04:06Z run, identical values on both sides).
   Both sides of every digest pass through this function first. An unparseable value is returned
   as-is rather than hidden, so a genuinely different string still mismatches. */
export function isoInstant(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null;
  const date = value instanceof Date ? value : new Date(String(value));
  return Number.isNaN(date.getTime()) ? String(value) : date.toISOString();
}
