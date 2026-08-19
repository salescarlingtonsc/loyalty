import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const root = path.resolve(import.meta.dirname, '../..');
const app = path.join(root, 'app');

async function text(relativePath) {
  return readFile(path.join(app, relativePath), 'utf8');
}

async function pngDimensions(relativePath) {
  const bytes = await readFile(path.join(app, relativePath));
  assert.deepEqual(
    [...bytes.subarray(0, 8)],
    [137, 80, 78, 71, 13, 10, 26, 10],
    `${relativePath} must be a PNG`
  );
  return {
    width: bytes.readUInt32BE(16),
    height: bytes.readUInt32BE(20)
  };
}

function serviceWorkerHarness(source, { fetchImpl, cacheKeys = [] } = {}) {
  const listeners = new Map();
  const openedCaches = [];
  const matchedPaths = [];
  const addedShells = [];
  const deletedCaches = [];
  const clientMessages = [];
  const clientNavigations = [];
  let skipWaitingCount = 0;
  const offlineResponse = Object.freeze({ kind: 'offline-document' });
  const cache = {
    async addAll(paths) {
      addedShells.push([...paths]);
    },
    async match(request) {
      const key = typeof request === 'string' ? request : new URL(request.url).pathname;
      matchedPaths.push(key);
      return key === '/offline.html' ? offlineResponse : undefined;
    }
  };
  const caches = {
    async open(name) {
      openedCaches.push(name);
      return cache;
    },
    async keys() {
      return cacheKeys;
    },
    async delete(key) {
      deletedCaches.push(key);
      return true;
    },
    async match(request) {
      return cache.match(request);
    }
  };
  const self = {
    location: { origin: 'https://www.peekaa.asia' },
    clients: {
      async claim() {},
      async matchAll() {
        return [
          {
            url: 'https://www.peekaa.asia/business#/',
            async navigate(url) {
              clientNavigations.push(url);
            },
            postMessage(message) {
              clientMessages.push(message);
            }
          }
        ];
      }
    },
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
    skipWaiting() {
      skipWaitingCount += 1;
    }
  };
  const context = vm.createContext({
    URL,
    caches,
    fetch: fetchImpl || (async () => {
      throw new TypeError('offline');
    }),
    self
  });
  vm.runInContext(source, context, { filename: 'app/sw.js' });
  return {
    addedShells,
    clientNavigations,
    clientMessages,
    deletedCaches,
    listeners,
    matchedPaths,
    offlineResponse,
    openedCaches,
    get skipWaitingCount() {
      return skipWaitingCount;
    }
  };
}

function request(url, overrides = {}) {
  return {
    method: 'GET',
    mode: 'same-origin',
    url,
    headers: { has: () => false },
    ...overrides
  };
}

async function dispatchFetch(listener, nextRequest) {
  let responsePromise;
  listener({
    request: nextRequest,
    respondWith(value) {
      responsePromise = Promise.resolve(value);
    }
  });
  return responsePromise;
}

test('manifest has a stable install identity and real maskable icons', async () => {
  const manifest = JSON.parse(await text('manifest.webmanifest'));

  assert.equal(manifest.id, '/');
  assert.equal(manifest.scope, '/');
  assert.equal(manifest.start_url, '/?source=pwa');
  assert.equal(manifest.display, 'standalone');
  assert.equal(manifest.name, 'Peekaa');
  assert.equal(manifest.short_name, 'Peekaa');
  assert.deepEqual(
    manifest.shortcuts.map(({ name, url }) => ({ name, url })),
    [
      /* V274: bare '/' now serves the marketing landing; every shortcut that means "the
         customer app" must say /app or a long-press shortcut opens marketing. */
      { name: 'Customer home', url: '/app' },
      { name: 'Business sign in', url: '/business' }
    ]
  );
  assert.deepEqual(
    manifest.icons.map(({ src, sizes, type, purpose }) => ({ src, sizes, type, purpose })),
    [
      {
        src: '/icons/peekaa-192.png',
        sizes: '192x192',
        type: 'image/png',
        purpose: 'any'
      },
      {
        src: '/icons/peekaa-512.png',
        sizes: '512x512',
        type: 'image/png',
        purpose: 'any'
      },
      {
        src: '/icons/peekaa-512-maskable.png',
        sizes: '512x512',
        type: 'image/png',
        purpose: 'maskable'
      }
    ]
  );
  assert.deepEqual(await pngDimensions('icons/peekaa-192.png'), { width: 192, height: 192 });
  assert.deepEqual(await pngDimensions('icons/peekaa-512.png'), { width: 512, height: 512 });
  assert.deepEqual(await pngDimensions('icons/peekaa-512-maskable.png'), { width: 512, height: 512 });
  assert.deepEqual(await pngDimensions('icons/apple-touch-icon.png'), { width: 180, height: 180 });
});

test('every installable page exposes consistent PWA and iOS metadata', async () => {
  const pages = [
    'index.html',
    'join.html',
    'privacy.html',
    'terms.html',
    'data-request.html',
    'offline.html'
  ];

  for (const page of pages) {
    const html = await text(page);
    assert.match(html, /viewport-fit=cover/, `${page} must opt into safe areas`);
    assert.match(html, /rel="manifest" href="\/manifest\.webmanifest"/, `${page} manifest`);
    assert.match(html, /apple-mobile-web-app-capable" content="yes"/, `${page} iOS mode`);
    assert.match(html, /rel="apple-touch-icon" sizes="180x180"/, `${page} iOS icon`);
    assert.match(html, /href="\/pwa\.css"/, `${page} PWA UI`);
    /* V321: /pwa.js is served with `public, max-age=14400, must-revalidate` and, unlike the
       app-*.js chunks, carries no build fingerprint — so a browser that already held it would run
       the OLD lifecycle script, and its auto-refresh, for up to four more hours after the fix
       deployed. The `?v=` query is the convention customer-ui.js already uses; bump it whenever
       pwa.js changes behaviour.

       It is applied to the three pages someone actually sits on with the app running, and
       deliberately NOT to privacy.html / terms.html / data-request.html: those documents' bytes
       are hashed into BUSINESS_LEGAL_V138 as the record of exactly what each owner accepted, so a
       cache-busting query would rewrite consent history to save a cache round-trip on a page
       nobody keeps open. They keep the unversioned tag and pick up the new script on their own
       revalidation. */
    const appPage = ['index.html', 'join.html', 'offline.html'].includes(page);
    assert.match(html, appPage ? /src="\/pwa\.js\?v=v321-no-self-refresh" defer/ : /src="\/pwa\.js" defer/,
      `${page} PWA lifecycle`);
  }
});

test('service worker installs the versioned fallback shell and waits for consent', async () => {
  const source = await text('sw.js');
  const harness = serviceWorkerHarness(source);
  let installPromise;

  harness.listeners.get('install')({
    waitUntil(value) {
      installPromise = Promise.resolve(value);
    }
  });
  await installPromise;

  /* V289: the install now has two phases. The first addAll is the static fallback set, which
     still must not contain a document — those are navigation targets, cached last and only as a
     complete set (see the shell-document test below). */
  const shell = harness.addedShells[0];
  assert.ok(shell.includes('/offline.html'));
  assert.ok(shell.includes('/manifest.webmanifest'));
  assert.ok(shell.includes('/icons/peekaa-512.png'));
  assert.ok(!shell.includes('/'));
  assert.ok(!shell.includes('/index.html'));
  assert.ok(!shell.includes('/app'));
  assert.ok(!shell.includes('/join.html'));
  assert.doesNotMatch(shell.join('\n'), /supabase|runtime-config|customer-ui|brand-config/i);
  /* V289 (audit A3, G3a): skipWaiting() on install forced a controller swap on every deploy,
     which reloaded customers mid-OTP and made pwa.js's isUnsafeToAutoUpdate() guard decorative.
     The worker must now WAIT; only the SKIP_WAITING message — sent by the guarded applyUpdate
     path — may promote it. */
  assert.equal(harness.skipWaitingCount, 0, 'an install must never take over a live page on its own');
  assert.match(source, /event\.data\?\.type==='SKIP_WAITING'\)self\.skipWaiting\(\)/,
    'the consented update path must still be able to promote the waiting worker');
});

test('V289: the offline app shell is stored only when every asset it needs is stored too', async () => {
  const source = await text('sw.js');
  /* cache.put is what writes the documents, and it may only ever run after the fingerprinted
     assets discovered in index.html have been added — so a half-cached shell cannot be served. */
  const precache = source.slice(source.indexOf('async function precacheShellDocumentsV289'));
  const addAll = precache.indexOf('cache.addAll([...assets])');
  const put = precache.indexOf('cache.put(document');
  assert.ok(addAll > 0 && put > addAll, 'the documents must be written after their assets');
  assert.match(precache, /<script\[\^>\]\+src="\(\[\^"\]\+\)"/,
    'the fingerprinted script urls must be read from the shipped document, never hardcoded');
  assert.match(precache, /appSurfaceChunks/, 'the router chunks must be precached too');
  assert.doesNotMatch(precache, /'business'/, 'the 1.2MB workspace chunk stays out of the shell');
});

test('service worker notifies but never re-navigates open pages after replacing a stale shell cache', async () => {
  const source = await text('sw.js');
  const harness = serviceWorkerHarness(source, {
    cacheKeys: [
      'nestly-shell-v5-20260802-v138-peekaa-convergence',
      'nestly-shell-v6-20260804-v164-auth-cache-convergence',
      'nestly-shell-v7-20260805-v167-customer-trust',
      'nestly-shell-v8-20260806-v177-production-polish',
      'nestly-shell-v9-20260808-v195-tier-icons',
      'nestly-shell-v10-20260812-v289-guarded-updates',
      'nestly-shell-v13-20260819-w2-polish',
      'unrelated-cache'
    ]
  });
  let activatePromise;

  harness.listeners.get('activate')({
    waitUntil(value) {
      activatePromise = Promise.resolve(value);
    }
  });
  await activatePromise;

  /* Every shell older than the current one goes, and only the current one survives — which is
     what makes a stale customer-ui.js impossible to keep. v8 joins the list because v195 is v9,
     and v10 joins it because v298 is v11. */
  assert.deepEqual(harness.deletedCaches, [
    'nestly-shell-v5-20260802-v138-peekaa-convergence',
    'nestly-shell-v6-20260804-v164-auth-cache-convergence',
    'nestly-shell-v7-20260805-v167-customer-trust',
    'nestly-shell-v8-20260806-v177-production-polish',
    'nestly-shell-v9-20260808-v195-tier-icons',
    /* V298: v10 joins the condemned list because v298 is v11 — the shell that cached the
       doubled-caption customer-ui.js must not survive activation. */
    'nestly-shell-v10-20260812-v289-guarded-updates'
  ]);
  assert.deepEqual(JSON.parse(JSON.stringify(harness.clientMessages)), [
    {
      type: 'PEEKAA_SW_ACTIVATED',
      cacheVersion: 'v13-20260819-w2-polish'
    }
  ]);
  /* V289 (audit A3, G3a): activation is now only reached through the guarded applyUpdate path,
     and the page that consented reloads itself via controllerchange. Re-navigating every window
     from the worker reloaded tabs that had consented to nothing — the same mid-OTP interruption
     from the other direction. The notification stays; the forced navigation does not. */
  assert.deepEqual(harness.clientNavigations, []);
});

test('brand and lifecycle assets prefer the network so an old Nestly shell cannot remain visible', async () => {
  const networkResponse = Object.freeze({ kind: 'fresh-peekaa-asset' });
  const harness = serviceWorkerHarness(await text('sw.js'), {
    fetchImpl: async () => networkResponse
  });

  for (const pathname of ['/pwa.js', '/manifest.webmanifest', '/brand/peekaa-logo.png']) {
    const response = await dispatchFetch(
      harness.listeners.get('fetch'),
      request(`https://www.peekaa.asia${pathname}`)
    );
    assert.equal(response, networkResponse, `${pathname} should refresh from the network`);
  }
  assert.deepEqual(harness.matchedPaths, []);
});

test('cold offline navigation returns the self-contained fallback when no shell is cached', async () => {
  const source = await text('sw.js');
  const harness = serviceWorkerHarness(source);
  const response = await dispatchFetch(
    harness.listeners.get('fetch'),
    request('https://www.peekaa.asia/#/customer', { mode: 'navigate' })
  );

  /* V289: the shell is tried first and, in this harness, is absent — so offline.html is still
     what an incomplete cache serves. A complete cache serves Peekaa's own document, which knows
     the route and shows the in-app offline banner. */
  assert.equal(response, harness.offlineResponse);
  assert.deepEqual(harness.matchedPaths, ['/index.html', '/offline.html']);
});

test('customer, business and admin navigation stay network-first and are never persisted by the service worker', async () => {
  const onlineResponse = Object.freeze({ kind: 'network-document' });
  let fetchCount = 0;
  const harness = serviceWorkerHarness(await text('sw.js'), {
    fetchImpl: async () => {
      fetchCount += 1;
      return onlineResponse;
    }
  });

  for (const route of ['/#/wallet', '/business', '/admin']) {
    const response = await dispatchFetch(
      harness.listeners.get('fetch'),
      request(`https://www.peekaa.asia${route}`, { mode: 'navigate' })
    );
    assert.equal(response, onlineResponse);
  }
  assert.equal(fetchCount, 3);
  assert.deepEqual(harness.matchedPaths, []);
});

test('authenticated, API, cross-origin and mutation requests bypass PWA caching', async () => {
  const harness = serviceWorkerHarness(await text('sw.js'));
  const fetchListener = harness.listeners.get('fetch');
  const cases = [
    request('https://www.peekaa.asia/api/session'),
    request('https://www.peekaa.asia/pwa.css', {
      headers: { has: (name) => name.toLowerCase() === 'authorization' }
    }),
    request('https://gadpooereceldfpfxsod.supabase.co/rest/v1/customers'),
    request('https://www.peekaa.asia/pwa.css', { method: 'POST' })
  ];

  for (const nextRequest of cases) {
    assert.equal(await dispatchFetch(fetchListener, nextRequest), undefined);
  }
  assert.deepEqual(harness.matchedPaths, []);
  assert.deepEqual(harness.openedCaches, []);
});

test('install, update and native-wrapper lifecycle contracts remain wired', async () => {
  const source = await text('pwa.js');

  assert.match(source, /beforeinstallprompt/);
  assert.match(source, /event\.preventDefault\(\)/);
  assert.match(source, /await event\.prompt\(\)/);
  assert.match(source, /event\.userChoice/);
  assert.match(source, /appinstalled/);
  assert.match(source, /registration\.waiting/);
  assert.match(source, /updatefound/);
  assert.match(source, /worker\.state==='installed'/);
  /* V321 (owner 2026-08-14: "the website still keeps refreshing itself. - remove this"). The
     1.2s auto-apply timer, the isUnsafeToAutoUpdate() guard that decided when a reload was
     "safe", and the PEEKAA_SW_ACTIVATED listener that reloaded OTHER tabs are all gone. What
     remains is an offer: a dismissible prompt, and a reload only once someone presses "Update
     now". These are inverted rather than deleted — the point is that none of it comes back. */
  /* Comments stripped: the note explaining a removal names the thing removed, and an assertion a
     comment can satisfy is no assertion. */
  const sourceCode = source.replace(/\/\*[\s\S]*?\*\//g,'').replace(/^\s*\/\/.*$/gm,'');
  assert.doesNotMatch(sourceCode, /isUnsafeToAutoUpdate/);
  assert.doesNotMatch(sourceCode, /autoUpdateTimer/);
  assert.doesNotMatch(sourceCode, /peekaa-sw-reloaded:/);
  assert.doesNotMatch(sourceCode, /PEEKAA_SW_ACTIVATED/);
  assert.match(source, /worker\.postMessage\(\{type:'SKIP_WAITING'\}\)/);
  assert.match(source, /controllerchange/);
  assert.match(source, /location\.reload\(\)/);
  assert.match(source, /register\(SW_URL,\{scope:'\/',updateViaCache:'none'\}\)/);
  assert.match(source, /Capacitor\?\.isNativePlatform/);
  assert.match(source, /navigator\?\.platform==='MacIntel'/);
});

test('mobile form controls avoid focus zoom and preserve app-safe touch sizing', async () => {
  const [pwaCss, index] = await Promise.all([
    text('pwa.css'),
    text('index.html')
  ]);
  assert.match(
    pwaCss,
    /@media\(max-width:768px\)[\s\S]+input,select,textarea\{font-size:16px!important\}/
  );
  assert.match(index, /input,select,textarea\{[\s\S]+min-height:44px/);
});

test('offline, safe-area and touch UI contracts are explicit', async () => {
  const [css, offline, vercel, wrapper] = await Promise.all([
    text('pwa.css'),
    text('offline.html'),
    text('vercel.json'),
    readFile(path.join(root, 'docs/mobile/capacitor-wrapper.md'), 'utf8')
  ]);

  assert.match(css, /safe-area-inset-top/);
  assert.match(css, /safe-area-inset-bottom/);
  assert.match(css, /100dvh/);
  assert.match(css, /touch-action:manipulation/);
  assert.match(css, /min-height:44px/);
  assert.match(css, /@media\(display-mode:standalone\)/);
  assert.match(offline, /cannot load live customer, booking or payment data/i);
  assert.match(vercel, /"source": "\/sw\.js"/);
  assert.match(vercel, /no-cache, no-store, must-revalidate/);
  assert.match(vercel, /Service-Worker-Allowed/);
  assert.match(vercel, /application\/manifest\+json/);
  assert.match(wrapper, /Capacitor/i);
  assert.match(wrapper, /future/i);
});
