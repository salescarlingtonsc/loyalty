import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { buildGraph } from '../../scripts/quality/app-surface-graph.mjs';
import {
  CUSTOMER_ENTRIES, AUTH_ENTRIES, BUSINESS_ENTRIES, I18N_TABLES, I18N_READER, OUTPUTS,
  SURFACE_PREREQUISITES, crossChunkViolations, partition, renderChunks
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
  for (const surface of ['auth', 'customer', 'business', 'i18n']) {
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
  const counts = { core: 0, auth: 0, customer: 0, business: 0, i18n: 0 };
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

test('a symbol two independently loaded surfaces can reach is shared, never surface-only', () => {
  const { customer, auth, business, blocks, placement } = partition(source);
  const home = new Map();
  for (const block of blocks) if (block.name) home.set(block.name, placement.get(block));
  /* The customer surface loads neither merchant chunk, so both of these pairs are independent.
     'auth' and 'business' are NOT a pair: the workspace chunk lists auth as a prerequisite, which
     is what lets the persona/suspension screens ship in the small chunk (see the next test). */
  const pairs = [['customer', customer, 'auth', auth], ['customer', customer, 'business', business]];
  for (const [leftName, left, rightName, right] of pairs) {
    for (const name of left) {
      if (!right.has(name)) continue;
      const where = home.get(name);
      /* The translation tables are the one sanctioned exception: both surfaces can reach them, but
         their single reader guards with typeof, so they ship separately. */
      if (I18N_TABLES.includes(name)) { assert.equal(where, 'i18n'); continue; }
      assert.ok(where === 'core' || where === undefined,
        `${name} is reachable from both ${leftName} and ${rightName} so it must be shared, not ${where}`);
    }
  }
});

/* V200. The auth chunk is the merchant's front door: sign in / sign up, pick a persona, accept a
   staff invite, activate an approved business, and the two "you cannot go further" cards. It must
   stand entirely on its own, because it is the ONLY chunk a signed-out visitor to /business gets. */
test('the auth chunk never reaches into the workspace chunk', () => {
  const { auth, blocks, placement } = partition(source);
  const home = new Map();
  for (const block of blocks) if (block.name) home.set(block.name, placement.get(block));
  for (const name of auth) {
    const where = home.get(name);
    assert.ok(where !== 'business' && where !== 'customer',
      `${name} is reachable from the sign-in screens but ships in the ${where} chunk`);
  }
  assert.deepEqual(SURFACE_PREREQUISITES, { business: ['auth'] },
    'the build and the runtime must agree on which chunk depends on which');
  assert.match(source, /const APP_SURFACE_PREREQUISITES_V185=\{business:\['auth'\]\}/,
    'app.js must declare the same dependency the split assumes');
  assert.match(source, /prerequisites=\(APP_SURFACE_PREREQUISITES_V185\[name\]\|\|\[\]\)\.map/);
});

test('a signed-out merchant gets the sign-in chunk, not the workspace', () => {
  assert.match(source, /return signedIn\?'business':'auth';/,
    'appSurfaceForRouteV185 must not hand a signed-out visitor the workspace bundle');
  const chunks = renderChunks(source);
  assert.ok(chunks.auth.length < chunks.business.length * 0.05,
    `the sign-in chunk must stay tiny (got ${(chunks.auth.length / 1024).toFixed(0)}KB against `
    + `${(chunks.business.length / 1024).toFixed(0)}KB of workspace)`);
  /* The preloader cannot see the session, so it must guess the CHEAP side — and auth is needed
     either way, since the workspace chunk pulls it in. */
  assert.match(indexHtml, /link\.href=manifest\[customer\?'customer':'auth'\]/);
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

/* ------------------------------------------------------- V200: the aux scripts follow the surface */

/* These five modules and their three stylesheets were <script defer>/<link> tags in index.html, so
   every visitor paid for all of them before first paint — including a customer opening a booking
   link, for globals only a workspace page ever touches. They now arrive with the surface chunk that
   consumes them. The pairing below is the contract: whichever chunk mentions a global must be the
   chunk whose asset list carries that global's file. */
const SURFACE_ASSET_GLOBALS = {
  'grow-recommender.js': 'FrenlyGrowRec',
  'v95-media-sync.js': 'NestlyMediaSyncV95',
  'revenue-truth.js': 'RevenueTruthUI',
  'growth-offers.js': 'NestlyGrowthOffers',
  'sector-economics.js': 'NestlySectorEconomics'
};

test('the deferred aux bundles no longer load on every first paint', () => {
  for (const file of Object.keys(SURFACE_ASSET_GLOBALS)) {
    assert.doesNotMatch(indexHtml, new RegExp(`<script src="/${file.replace('.', '\\.')}`),
      `${file} must load with its surface, not on every page load`);
  }
  for (const style of ['revenue-truth.css', 'growth-offers.css', 'sector-economics.css']) {
    assert.doesNotMatch(indexHtml, new RegExp(`<link rel="stylesheet" href="/${style.replace('.', '\\.')}`),
      `${style} styles a surface that has not loaded yet`);
  }
  /* platform-crm-utils.js has exactly one consumer, platform-console.js, so it moved onto the
     console's own on-demand path instead of a surface list. */
  assert.doesNotMatch(indexHtml, /<script src="\/platform-crm-utils\.js/);
  assert.match(indexHtml, /"crm":"\/platform-crm-utils\.js/,
    'it must still be reachable — through the platform console manifest');
  /* What is left in the initial load runs at load time and must stay. */
  for (const kept of ['native-bridge.js', 'pwa.js', 'customer-push.js', 'brand-config.js',
    'runtime-config.js', 'runtime-config-loader.js', 'customer-ui.js']) {
    assert.match(indexHtml, new RegExp(`<script src="/${kept.replace('.', '\\.')}`),
      `${kept} runs at load time and must not be deferred to a surface`);
  }
});

test('every surface asset is listed for exactly the chunks that consume its global', async () => {
  const manifest = JSON.parse(indexHtml.match(
    /<script type="application\/json" id="appSurfaceAssets">\n([\s\S]*?)\n<\/script>/)[1]);
  const chunks = renderChunks(source);
  for (const [file, global] of Object.entries(SURFACE_ASSET_GLOBALS)) {
    for (const surface of ['auth', 'customer', 'business']) {
      const listed = (manifest[surface]?.js || []).some((url) => url.startsWith(`/${file}`));
      const used = chunks[surface].includes(global);
      assert.equal(listed, used,
        `${file} is ${listed ? '' : 'not '}listed for the ${surface} chunk but that chunk does `
        + `${used ? '' : 'not '}use ${global}`);
    }
    /* A load-time reference would run before the chunk that owns it — and the core is what loads
       first, so the core must never touch one of these globals at all. */
    assert.equal(chunks.core.includes(global), false,
      `${global} is referenced from the always-loaded core, which now loads before its script`);
  }
  /* Same-origin paths only: this manifest is injected as <script src>. */
  for (const entry of Object.values(manifest)) {
    for (const url of [...(entry.js || []), ...(entry.css || [])]) {
      assert.match(url, /^\/[\w./?=-]*$/, `${url} must be a same-origin absolute path`);
      await readFile(new URL(`app${url.split('?')[0]}`, root), 'utf8');
    }
  }
});

test('surface assets are injected before the chunk that needs them, and never block it', () => {
  assert.match(source, /const APP_SURFACE_ASSETS_V200=\(\(\)=>\{/);
  assert.match(source, /document\.getElementById\('appSurfaceAssets'\)/);
  assert.match(source, /prerequisites\.push\(loadSurfaceAssetsV200\(name\)\)/,
    'the chunk must not execute before its assets');
  /* Insertion order under async=false is the whole guarantee: even a future load-time read of one
     of these globals resolves, because the asset tag was appended first. */
  const loader = source.slice(source.indexOf('function loadSurfaceAssetV200('));
  assert.match(loader.slice(0, loader.indexOf('function loadSurfaceAssetsV200')), /node\.async=false/);
  assert.match(source, /node\.onerror=\(\)=>\{console\.error\(`Surface asset failed to load/,
    'a missing enhancement must not stop the surface from rendering');
  /* `defer` is ignored on a dynamically created script; only async=false orders it after the CRM
     helper that platform-console.js reads at ITS load time. */
  assert.match(source, /script\.src=scriptUrl;script\.async=false;/);
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
  for (const name of [...CUSTOMER_ENTRIES, ...AUTH_ENTRIES, ...BUSINESS_ENTRIES]) {
    assert.ok(source.includes(`function ${name}(`), `${name} no longer exists in app/app.js`);
    assert.ok(source.includes(name), `${name} must still be dispatched by the router`);
  }
});
