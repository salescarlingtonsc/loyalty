import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { buildGraph } from '../../scripts/quality/app-surface-graph.mjs';
import {
  CUSTOMER_ENTRIES, BUSINESS_ENTRIES, I18N_TABLES, I18N_READER, OUTPUTS,
  crossChunkViolations, partition, renderChunks
} from '../../scripts/quality/split-app-bundle.mjs';
import { build, chunkUrls } from '../../scripts/quality/stamp-app-bundle.mjs';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const source = await read('app/app.js');
const indexHtml = await read('app/index.html');

/* ------------------------------------------------------------------ the build is current */

test('the shipped surface bundles are exactly what app/app.js produces', async () => {
  const chunks = renderChunks(source);
  for (const [surface, target] of Object.entries(OUTPUTS)) {
    assert.equal(await read(target), chunks[surface],
      `${target} is stale. Run: npm run bundle-stamp`);
  }
});

test('index.html is stamped for the bytes of the chunks it ships with', async () => {
  const { document, stamped } = await build();
  assert.equal(document, stamped, 'app/index.html is stale. Run: npm run bundle-stamp');
  const urls = chunkUrls(renderChunks(source));
  assert.match(indexHtml, new RegExp(`<script src="${urls.core.replace('?', '\\?')}" defer></script>`));
  for (const surface of ['customer', 'business', 'i18n']) {
    assert.ok(indexHtml.includes(`"${surface}":"${urls[surface]}"`),
      `the manifest must point at the current ${surface} bytes`);
  }
  assert.match(urls.core, /^\/app-core\.js\?b=[0-9a-f]{12}$/);
});

/* ------------------------------------------------------------- nothing is lost or duplicated */

test('the chunks reassemble into app/app.js byte for byte', () => {
  const { blocks } = partition(source);
  assert.equal(blocks.map((block) => block.text).join('\n'), source,
    'the partition must never rewrite, drop or reorder a line');
});

test('every top-level symbol lands in exactly one chunk', () => {
  const { blocks, placement } = partition(source);
  const seen = new Map();
  for (const block of blocks) {
    if (!block.name) continue;
    assert.equal(seen.has(block.name), false, `${block.name} is declared twice`);
    seen.set(block.name, placement.get(block));
  }
  const counts = { core: 0, customer: 0, business: 0, i18n: 0 };
  for (const surface of seen.values()) counts[surface] += 1;
  for (const [surface, count] of Object.entries(counts)) {
    assert.ok(count > 0, `${surface} chunk must not be empty`);
  }
});

/* -------------------------------------------------- the invariant the whole split rests on */

test('no chunk references a symbol that lives in another independently loaded chunk', () => {
  const violations = crossChunkViolations(source);
  assert.deepEqual(violations, [],
    violations.map((item) => `${item.from}:${item.block} -> ${item.to}:${item.ref}`).join('\n'));
});

test('a symbol either surface can reach is shared, never surface-only', () => {
  const { customer, business, blocks, placement } = partition(source);
  const home = new Map();
  for (const block of blocks) if (block.name) home.set(block.name, placement.get(block));
  for (const name of customer) {
    if (!business.has(name)) continue;
    const where = home.get(name);
    /* The translation tables are the one sanctioned exception: both surfaces can reach them, but
       their single reader guards with typeof, so they ship separately. */
    if (I18N_TABLES.includes(name)) { assert.equal(where, 'i18n'); continue; }
    assert.ok(where === 'core' || where === undefined,
      `${name} is reachable from both surfaces so it must be shared, not ${where}`);
  }
});

test('markup handlers ship with the page that renders them', () => {
  const { blocks, placement } = partition(source);
  const home = new Map();
  for (const block of blocks) if (block.name) home.set(block.name, placement.get(block));
  const inline = [...source.matchAll(/\bon[a-z]+="\s*([A-Za-z_$][\w$]*)\s*\(/g)].map((match) => match[1]);
  assert.ok(inline.length > 20, 'expected the workspace to still use inline handlers');
  for (const block of blocks) {
    for (const match of block.text.matchAll(/\bon[a-z]+="\s*([A-Za-z_$][\w$]*)\s*\(/g)) {
      const handler = match[1];
      if (!home.has(handler) || handler === block.name) continue;
      const target = home.get(handler);
      assert.ok(target === 'core' || target === placement.get(block),
        `${block.name} renders onclick="${handler}(" but that handler ships in the ${target} chunk`);
    }
  }
});

/* ------------------------------------------------------------------------- the runtime */

test('the router resolves the surface after the session and awaits it before dispatching', () => {
  assert.match(source, /const appSurfaceV185=appSurfaceForRouteV185\(h,\{signedIn:!!S\.user\}\)/);
  assert.match(source, /if\(appSurfaceV185\)await loadAppChunkV185\(appSurfaceV185\)/);
  const route = source.slice(source.indexOf('async function route(){'));
  const session = route.indexOf('await sb.auth.getSession()');
  const surface = route.indexOf('appSurfaceForRouteV185');
  const firstDispatch = route.indexOf("if(h.startsWith('#/b/'))");
  assert.ok(session > 0 && surface > session, 'the surface decision needs the resolved session');
  assert.ok(firstDispatch > surface, 'no route may dispatch before its chunk is awaited');
});

test('a misclassified route self-heals instead of showing an error', () => {
  assert.match(source, /if\(e instanceof ReferenceError&&!appSurfaceRetriedV185\)\{/);
  assert.match(source, /await Promise\.allSettled\(\[loadAppChunkV185\('customer'\),loadAppChunkV185\('business'\)\]\)/);
  assert.match(source, /appSurfaceRetriedV185=true/, 'the retry must happen at most once');
});

test('chunk urls come from the manifest and can only be same-origin paths', () => {
  assert.match(source, /document\.getElementById\('appSurfaceChunks'\)/);
  assert.match(source, /if\(!\/\^\\\/\[\\w\.\/\?=-\]\*\$\/\.test\(src\)\)/,
    'a tampered manifest must not become a script injection');
  assert.match(source, /script\.async=false/);
  assert.match(source, /appChunkPromisesV185\.delete\(name\)/, 'a failed load must stay retryable');
});

test('the preloader in index.html mirrors the router rule it races', () => {
  const prefixes = source.match(/const CUSTOMER_ROUTE_PREFIXES_V185=\[([^\]]+)\]/)[1];
  const inline = indexHtml.match(/var customer=\[([^\]]+)\]/)[1];
  assert.equal(inline, prefixes, 'the inline preloader and appSurfaceForRouteV185 must agree');
  assert.match(indexHtml, /link\.rel='preload';link\.as='script'/, 'it preloads — it must never execute');
  assert.match(indexHtml, /if\(hash\.indexOf\('#\/platform'\)===0\)return/);
});

/* V199. This assertion used to read "a signed-in visitor at '#/' needs the workspace" and pinned
   the preloader's auth-token sniff. It was pinning a route that does not exist: route() dispatches
   "#/" to renderCustomerRegistration with no signed-in check at all, and that renderer forwards a
   customer who already has a profile on to #/wallet. Staff reach the workspace via #/business.
   The mismatch cost every signed-in visitor to the bare root a ReferenceError and a fallback
   download of EVERY surface, which the self-heal hid as mere slowness. */
test('"#/" resolves to the customer surface for everyone, matching the route it feeds', () => {
  assert.match(source, /if\(route==='#\/'\|\|route===''\)return 'customer';/);
  assert.match(indexHtml, /\}\)\|\|hash===''\|\|hash==='#\/';/);
  assert.doesNotMatch(indexHtml, /\/\^sb-\.\+-auth-token\$\//,
    'the preloader must not branch on sign-in state for a route that never varies by it');
  // the router rule this mirrors: "#/" dispatches to the customer renderer unconditionally
  assert.match(source, /if\(h==='#\/'\|\|h==='#\/customer'\|\|h==='#\/customer\/register'\|\|h\.startsWith\('#\/customer\?'\)\) return renderCustomerRegistration\(isRouteCurrent\)/);
});

test('only the core is loaded eagerly', () => {
  const tags = [...indexHtml.matchAll(/<script src="\/app-([a-z0-9]+)\.js[^"]*"/g)].map((match) => match[1]);
  assert.deepEqual(tags, ['core'], 'the surface chunks must not be plain script tags');
  assert.doesNotMatch(indexHtml, /<script src="\/app\.js/, 'the unsplit bundle must not be shipped');
});

/* ---------------------------------------------------------------------------- the i18n chunk */

test('the translation tables have exactly one reader and it degrades to English', () => {
  const { byName } = buildGraph(source);
  for (const table of I18N_TABLES) {
    const readers = [...byName.values()].filter((block) => block.name !== table && block.refs.has(table));
    assert.deepEqual(readers.map((block) => block.name), [I18N_READER],
      `${table} may only be read by ${I18N_READER}, which guards with typeof`);
  }
  assert.match(source, /typeof WORKSPACE_GENERATED_COPY_V97==='undefined'\s*\n?\s*\?source/,
    'an unloaded table must fall back to the English source, not throw');
  assert.match(source, /if\(workspaceLocale!=='en'\)await loadWorkspaceI18nV185\(\)/,
    'a translated workspace must not paint an English frame first');
  assert.match(source, /if\(next!=='en'\)await loadWorkspaceI18nV185\(\)/,
    'switching language must wait for the tables');
});

/* ------------------------------------------------------------------------ what this buys */

test('the customer downloads a fraction of the workspace bundle', () => {
  const chunks = renderChunks(source);
  const customerBytes = chunks.core.length + chunks.customer.length;
  const everything = Object.values(chunks).reduce((total, text) => total + text.length, 0);
  assert.ok(customerBytes < everything * 0.35,
    `a customer should download well under a third of the app (got ${(customerBytes / everything * 100).toFixed(0)}%)`);
  assert.ok(chunks.business.length > chunks.customer.length * 2,
    'the workspace is the bulk — if this flips, the entry lists are probably wrong');
});

test('the surface entry lists still match the router', () => {
  for (const name of [...CUSTOMER_ENTRIES, ...BUSINESS_ENTRIES]) {
    assert.ok(source.includes(`function ${name}(`), `${name} no longer exists in app/app.js`);
    assert.ok(source.includes(name), `${name} must still be dispatched by the router`);
  }
});
