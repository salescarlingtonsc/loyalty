#!/usr/bin/env node
/**
 * Generate the per-surface bundles from app/app.js.
 *
 *   node scripts/quality/split-app-bundle.mjs --write   # after any app/app.js edit
 *   node scripts/quality/split-app-bundle.mjs --check   # enforced by the test suite
 *
 * app/app.js stays the single editable source. This partitions its TOP-LEVEL BLOCKS — it never
 * rewrites a line — so the three generated files concatenate back to the original byte for byte,
 * in the original order. A customer opening a booking link downloads core + customer and never
 * sees the workspace's till, reports, inventory or settings code.
 *
 * Placement rules, in order:
 *   1. every block that RUNS at load time is core, and so is everything it needs;
 *   2. a block reachable from both surfaces is core (loaded once, shared);
 *   3. what is left is surface-only and ships with its surface.
 * Rule 2 is what makes cross-chunk calls impossible: a symbol a customer path can reach is never
 * placed in the business chunk.
 *
 * v200: 'auth' is a FOURTH surface carved out of the workspace one. A signed-out merchant landing
 * on /business used to download the whole 1.2MB workspace to be shown a login card. The sign-in /
 * persona / invite-accept screens are now their own ~16KB chunk. The business surface DEPENDS on
 * it (loadAppChunkV185 pulls 'auth' in before 'business'), because several of those screens are
 * also reached signed in — a persona chooser, a workspace-suspended card, an invite acceptance.
 * That dependency is the one asymmetry in the model: a business block may reference an auth symbol,
 * never the reverse, and a customer path may reach neither, so anything the customer surface also
 * touches falls back to the core exactly as before.
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildGraph, closure } from './app-surface-graph.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const SOURCE = 'app/app.js';
export const OUTPUTS = {
  core: 'app/app-core.js',
  auth: 'app/app-auth.js',
  customer: 'app/app-customer.js',
  business: 'app/app-business.js',
  i18n: 'app/app-i18n.js'
};

/* Surfaces that cannot stand alone. The runtime honours the same table (loadAppChunkV185 in
   app/app.js), and it is what lets an auth symbol also be called from a signed-in workspace path
   without being promoted to the core. Keep the two in step. */
export const SURFACE_PREREQUISITES = { business: ['auth'] };

/* The zh-CN / ms lookup tables: ~200KB of source consulted only when the active locale is not
   English. They are pure data with exactly one reader, which guards with `typeof`, so they can
   ship separately and arrive late without breaking anything. */
export const I18N_TABLES = ['WORKSPACE_COPY_V97', 'WORKSPACE_GENERATED_COPY_V97'];
export const I18N_READER = 'workspaceTranslationV97';

/* The names route() dispatches to. These are the ONLY edges that are cut; everything else is a
   normal dependency. Keep them in sync with the router — the test fails if a name disappears. */
export const CUSTOMER_ENTRIES = [
  'renderPortal', 'renderCustomerRegistration', 'renderCustomerClaim', 'renderCustomerQrJoin',
  'renderCustomerProgrammes', 'renderCustomerBookings', 'renderCustomerMessages',
  'renderCustomerProfile', 'renderCustomerWallet', 'renderCustomerWalletUnavailable',
  'renderCustomerCapabilityRetry', 'renderCustomerRecoveryPasswordSetup',
  'renderCustomerFirstProgrammeQuest', 'renderCustomerCommunicationsV263'
];
/* v200: the way IN to the workspace — sign in / sign up, pick a persona, accept a staff invite,
   activate an approved business, and the two "you cannot go further" cards. A signed-out merchant
   opening /business renders one of these and nothing else, so they are their own small chunk
   instead of the first 16KB of a 1.2MB download. Several are ALSO reached signed in (a persona
   chooser, a suspended-workspace card), which is why 'business' declares 'auth' as a prerequisite
   rather than the two being independent. */
export const AUTH_ENTRIES = [
  'renderAuth', 'renderPersonaChoice', 'renderBusinessSignupChoice',
  'renderApprovedBusinessActivation', 'renderBusinessStaffInviteAcceptV151',
  'renderStaffInviteAuthV151', 'renderPersonaResolutionUnavailable',
  'renderWorkspaceAccessUnavailable', 'renderBusinessWorkspaceControl'
];
export const BUSINESS_ENTRIES = [
  'renderShell', 'renderOnboard', 'loadWorkspaceLocaleV97'
];

export function partition(source) {
  const { blocks, byName } = buildGraph(source);
  const entries = [...CUSTOMER_ENTRIES, ...AUTH_ENTRIES, ...BUSINESS_ENTRIES];
  const missing = entries.filter((name) => !byName.has(name));
  if (missing.length) throw new Error(`surface entry points not found in ${SOURCE}: ${missing.join(', ')}`);

  const severed = new Map([['route', new Set(entries)]]);
  const loadTimeSeeds = new Set();
  for (const block of blocks) {
    if (!block.executes) continue;
    for (const ref of block.refs) loadTimeSeeds.add(ref);
  }
  /* route/boot and the load-time statements are the core's own roots. */
  const coreRoots = new Set([...loadTimeSeeds, 'route', 'boot']);
  const core = closure(coreRoots, byName, severed);
  const customer = closure(CUSTOMER_ENTRIES, byName, severed);
  const auth = closure(AUTH_ENTRIES, byName, severed);
  const business = closure(BUSINESS_ENTRIES, byName, severed);

  /* Guard the one assumption the i18n chunk rests on: exactly one reader, and it is the guarded
     translator. A new direct reader would run before the chunk arrives and throw. */
  for (const table of I18N_TABLES) {
    const readers = blocks.filter((block) => block.name !== table && block.refs.has(table)).map((block) => block.name);
    const unexpected = readers.filter((name) => name !== I18N_READER);
    if (unexpected.length) {
      throw new Error(`${table} is read by ${unexpected.join(', ')}; only ${I18N_READER} may read it (it guards with typeof). Add a guard or keep the table in the core.`);
    }
  }

  const placement = new Map();
  for (const block of blocks) {
    if (!block.name) { placement.set(block, 'core'); continue; }
    const name = block.name;
    if (I18N_TABLES.includes(name)) { placement.set(block, 'i18n'); continue; }
    if (core.has(name)) { placement.set(block, 'core'); continue; }
    const inCustomer = customer.has(name);
    const inAuth = auth.has(name);
    const inBusiness = business.has(name);
    /* The customer surface loads neither of the merchant chunks, so anything it shares with either
       of them is shared code and belongs in the core — the original rule 2, unchanged. */
    if (inCustomer && (inAuth || inBusiness)) { placement.set(block, 'core'); continue; }
    /* Auth beats business deliberately: 'business' always drags 'auth' in with it, so a symbol both
       reach is safe in the smaller chunk, and the signed-out visitor gets it without the workspace. */
    if (inAuth) { placement.set(block, 'auth'); continue; }
    if (inCustomer) { placement.set(block, 'customer'); continue; }
    if (inBusiness) { placement.set(block, 'business'); continue; }
    /* Unreachable from any surface — provisionally core, then settled below. */
    placement.set(block, 'core');
  }

  /* Blocks no entry point reaches (dead code, or code wired up only through markup we cannot see)
     land in the core by default. That is safe for THEM, but not for the core: several call
     workspace-only helpers, which would be missing whenever the workspace chunk has not loaded.
     Settle each one into the surface it actually depends on. Repeat to a fixed point, since an
     orphan may depend on another orphan. */
  const orphans = blocks.filter((block) => block.name
    && !core.has(block.name) && !customer.has(block.name) && !auth.has(block.name)
    && !business.has(block.name) && !I18N_TABLES.includes(block.name));
  const home = new Map();
  for (const block of blocks) if (block.name) home.set(block.name, placement.get(block));
  for (let pass = 0; pass < 8; pass += 1) {
    let moved = false;
    for (const block of orphans) {
      if (placement.get(block) !== 'core') continue;
      const surfaces = new Set();
      for (const ref of block.refs) {
        const where = home.get(ref);
        if (where === 'customer' || where === 'auth' || where === 'business') surfaces.add(where);
      }
      /* An orphan that needs auth AND business symbols still has one legal home: the business
         chunk, which never loads without auth. Any other mixture spans independent chunks, so it
         stays in the core. */
      const surface = surfaces.size === 1 ? [...surfaces][0]
        : (surfaces.size === 2 && surfaces.has('auth') && surfaces.has('business')) ? 'business' : null;
      if (!surface) continue;
      placement.set(block, surface);
      home.set(block.name, surface);
      moved = true;
    }
    if (!moved) break;
  }
  return { blocks, placement, byName, core, customer, auth, business, orphans };
}

/**
 * The invariant the whole split rests on: no chunk may reference a symbol that lives in a
 * different, independently loaded chunk. "Independently" is the operative word — a chunk may reach
 * into one of its own prerequisites (business -> auth), because that one is guaranteed to have been
 * injected first. The two sanctioned exceptions beyond that are the router's dispatch to the
 * surface entry points (it awaits the chunk first) and the translation tables (their one reader
 * guards with `typeof`).
 */
export function crossChunkViolations(source) {
  const { blocks, placement } = partition(source);
  const home = new Map();
  for (const block of blocks) if (block.name) home.set(block.name, placement.get(block));
  const dispatched = new Set([...CUSTOMER_ENTRIES, ...AUTH_ENTRIES, ...BUSINESS_ENTRIES]);
  const violations = [];
  for (const block of blocks) {
    const from = placement.get(block);
    const available = SURFACE_PREREQUISITES[from] || [];
    for (const ref of block.refs) {
      const to = home.get(ref);
      if (!to || to === from || to === 'core') continue;
      if (available.includes(to)) continue;
      if (block.name === 'route' && dispatched.has(ref)) continue;
      if (to === 'i18n' && ref === I18N_TABLES.find((table) => table === ref) && block.name === I18N_READER) continue;
      violations.push({ from, block: block.name, to, ref });
    }
  }
  return violations;
}

const SURFACE_LABELS = {
  core: 'shared core',
  auth: 'merchant sign-in, persona and invite screens',
  customer: 'customer',
  business: 'business workspace',
  i18n: 'zh-CN / ms translation tables'
};
export function renderChunks(source) {
  const { blocks, placement } = partition(source);
  const parts = { core: [], auth: [], customer: [], business: [], i18n: [] };
  for (const block of blocks) parts[placement.get(block)].push(block.text);
  const chunks = {};
  for (const [surface, texts] of Object.entries(parts)) {
    chunks[surface] = `/* GENERATED FILE — do not edit.\n`
      + `   The ${SURFACE_LABELS[surface]} of app/app.js, split by scripts/quality/split-app-bundle.mjs.\n`
      + `   Edit app/app.js and run: npm run bundle-stamp */\n${texts.join('\n')}\n`;
  }
  return chunks;
}

export function fingerprint(text) {
  return createHash('sha256').update(text).digest('hex').slice(0, 12);
}

async function main() {
  const check = process.argv.includes('--check');
  const write = process.argv.includes('--write');
  if (check === write) throw new Error('Usage: node scripts/quality/split-app-bundle.mjs --write|--check');
  const source = await readFile(path.join(repoRoot, SOURCE), 'utf8');
  const chunks = renderChunks(source);
  let stale = false;
  for (const [surface, target] of Object.entries(OUTPUTS)) {
    const expected = chunks[surface];
    const current = await readFile(path.join(repoRoot, target), 'utf8').catch(() => null);
    if (current === expected) continue;
    stale = true;
    if (write) await writeFile(path.join(repoRoot, target), expected);
    else console.error(`${target} is stale (${current === null ? 'missing' : 'differs'}).`);
  }
  const sizes = Object.entries(chunks)
    .map(([surface, text]) => `${surface} ${(text.length / 1024).toFixed(0)}KB`).join(' · ');
  if (check) {
    if (stale) { console.error('Run: npm run bundle-stamp'); process.exitCode = 1; return; }
    console.log(`Surface bundles are current (${sizes}).`);
    return;
  }
  console.log(`Wrote surface bundles: ${sizes}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
