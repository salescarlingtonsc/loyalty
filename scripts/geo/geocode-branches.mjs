#!/usr/bin/env node
/* v247 — turn branch addresses into coordinates so Explore can sort nearest first.
 *
 * Geocoder: OneMap (https://www.onemap.gov.sg), Singapore's official mapping service. Chosen
 * because the platform is Singapore-first, its search API needs no key and no account, and it
 * resolves local forms — block numbers, street abbreviations, postal codes — that a global
 * geocoder guesses at. Nothing but the branch's own public street address is sent.
 *
 * Idempotent by provenance: a branch is geocoded only when it has an address AND the stored
 * geocoded_address differs from it. Re-running after nothing changed does no writes and no
 * network calls. --force re-geocodes everything with an address.
 *
 * A result is REFUSED unless OneMap returns a single confident match with usable coordinates, and
 * refusals are reported. A wrong pin is worse than no pin: no pin says "we don't know", a wrong
 * pin sends a customer to the wrong shop.
 *
 * Usage:
 *   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/geo/geocode-branches.mjs [--dry-run] [--force]
 */

import { pathToFileURL } from 'node:url';

const ONEMAP_SEARCH = 'https://www.onemap.gov.sg/api/common/elastic/search';
const SG_BOUNDS = { minLat: 1.13, maxLat: 1.51, minLng: 103.58, maxLng: 104.14 };

export function config(env = process.env) {
  const url = String(env.SUPABASE_URL || '').trim().replace(/\/$/, '');
  const serviceKey = String(env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  if (!url) throw new Error('SUPABASE_URL is required');
  if (!serviceKey) throw new Error('SUPABASE_SERVICE_ROLE_KEY is required');
  return { url, serviceKey };
}

/* OneMap answers with every partial match it can think of. Only an unambiguous hit is accepted:
 * exactly one result, or a clear best result whose coordinates land inside Singapore. */
export function pickResult(payload) {
  const results = Array.isArray(payload?.results) ? payload.results : [];
  if (!results.length) return { ok: false, reason: 'no match' };
  const usable = results
    .map((row) => ({
      lat: Number(row?.LATITUDE),
      lng: Number(row?.LONGITUDE),
      label: String(row?.ADDRESS || row?.SEARCHVAL || '').trim()
    }))
    .filter((row) => Number.isFinite(row.lat) && Number.isFinite(row.lng)
      && row.lat >= SG_BOUNDS.minLat && row.lat <= SG_BOUNDS.maxLat
      && row.lng >= SG_BOUNDS.minLng && row.lng <= SG_BOUNDS.maxLng);
  if (!usable.length) return { ok: false, reason: 'no result inside Singapore' };
  /* Several results that all point at the same building (different units) are one place, not an
   * ambiguity. Distinct buildings are: the caller must give a better address. */
  const spread = usable.some((row) =>
    Math.abs(row.lat - usable[0].lat) > 0.002 || Math.abs(row.lng - usable[0].lng) > 0.002);
  if (spread && usable.length > 1) return { ok: false, reason: `ambiguous (${usable.length} distinct places)` };
  return { ok: true, ...usable[0] };
}

async function rest(cfg, path, init = {}) {
  const response = await fetch(`${cfg.url}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: cfg.serviceKey,
      authorization: `Bearer ${cfg.serviceKey}`,
      'content-type': 'application/json',
      prefer: 'return=representation',
      ...(init.headers || {})
    }
  });
  if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
  return response.status === 204 ? null : response.json();
}

/* OneMap matches Singapore address FORMS, not free text: "313 Orchard Road" resolves, while the
 * same address with its postal suffix — "313 Orchard Road, Singapore 238895" — returns nothing,
 * and a unit number kills it too. Real owners type the full thing, so the candidates are tried
 * strongest-signal first: the six-digit postal code (unique to one building in Singapore), then
 * the address stripped of unit and country noise, then the raw text. Verified against the live
 * API for both a mall address and an HDB block address. */
export function searchCandidates(address) {
  const raw = String(address || '').trim();
  if (!raw) return [];
  const candidates = [];
  const postal = raw.match(/\b(\d{6})\b/);
  if (postal) candidates.push(postal[1]);
  const stripped = raw
    .replace(/#[\d]+[-–][\dA-Za-z]+/g, ' ')          // unit numbers
    .replace(/\bsingapore\b/gi, ' ')                 // country
    .replace(/\b\d{6}\b/g, ' ')                      // postal, already tried alone
    .replace(/[,;]+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
  if (stripped && stripped.toLowerCase() !== raw.toLowerCase()) candidates.push(stripped);
  candidates.push(raw);
  return [...new Set(candidates.filter(Boolean))];
}

async function geocode(address) {
  let lastReason = 'no match';
  for (const candidate of searchCandidates(address)) {
    const url = `${ONEMAP_SEARCH}?searchVal=${encodeURIComponent(candidate)}&returnGeom=Y&getAddrDetails=Y&pageNum=1`;
    const response = await fetch(url, { headers: { accept: 'application/json' } });
    if (!response.ok) { lastReason = `OneMap ${response.status}`; continue; }
    const result = pickResult(await response.json());
    if (result.ok) return { ...result, matchedOn: candidate };
    lastReason = result.reason;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return { ok: false, reason: lastReason };
}

export async function run({ dryRun = false, force = false, env = process.env, log = console.log } = {}) {
  const cfg = config(env);
  const branches = await rest(cfg, 'branches?select=id,name,address,latitude,longitude,geocoded_address&address=not.is.null&order=name');
  const pending = branches.filter((branch) => {
    const address = String(branch.address || '').trim();
    if (!address) return false;
    if (force) return true;
    return String(branch.geocoded_address || '').trim() !== address;
  });

  log(`${branches.length} branch(es) with an address; ${pending.length} need geocoding${force ? ' (forced)' : ''}.`);
  const summary = { located: 0, refused: 0, skipped: branches.length - pending.length, refusals: [] };

  for (const branch of pending) {
    const address = String(branch.address).trim();
    const result = await geocode(address);
    if (!result.ok) {
      summary.refused += 1;
      summary.refusals.push({ branch: branch.name, address, reason: result.reason });
      log(`  ✗ ${branch.name}: "${address}" — ${result.reason}`);
      continue;
    }
    log(`  ✓ ${branch.name}: "${address}" → ${result.lat}, ${result.lng} (${result.label}${result.matchedOn===address?'':`, matched on "${result.matchedOn}"`})`);
    if (!dryRun) {
      await rest(cfg, `branches?id=eq.${branch.id}`, {
        method: 'PATCH',
        body: JSON.stringify({
          latitude: result.lat,
          longitude: result.lng,
          geocoded_address: address,
          geocoded_at: new Date().toISOString(),
          geocode_source: 'onemap'
        })
      });
    }
    summary.located += 1;
    // OneMap asks for restraint; this is a handful of rows, so one call a second is plenty.
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }

  log(`Located ${summary.located}, refused ${summary.refused}, unchanged ${summary.skipped}${dryRun ? ' (dry run — nothing written)' : ''}.`);
  if (summary.refusals.length) {
    log('Refused (a wrong pin is worse than no pin — fix the address and re-run):');
    for (const row of summary.refusals) log(`  - ${row.branch}: "${row.address}" (${row.reason})`);
  }
  return summary;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  run({ dryRun: process.argv.includes('--dry-run'), force: process.argv.includes('--force') })
    .catch((error) => { console.error(error.message); process.exitCode = 1; });
}
