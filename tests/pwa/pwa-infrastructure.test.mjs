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

function serviceWorkerHarness(source, { fetchImpl } = {}) {
  const listeners = new Map();
  const openedCaches = [];
  const matchedPaths = [];
  const addedShells = [];
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
      return [];
    },
    async delete() {
      return true;
    },
    async match(request) {
      return cache.match(request);
    }
  };
  const self = {
    location: { origin: 'https://www.nestly.asia' },
    clients: { async claim() {} },
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
    skipWaiting() {}
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
    listeners,
    matchedPaths,
    offlineResponse,
    openedCaches
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
  assert.equal(manifest.name, 'Nestly');
  assert.equal(manifest.short_name, 'Nestly');
  assert.deepEqual(
    manifest.icons.map(({ src, sizes, type, purpose }) => ({ src, sizes, type, purpose })),
    [
      {
        src: '/icons/nestly-192.png',
        sizes: '192x192',
        type: 'image/png',
        purpose: 'any maskable'
      },
      {
        src: '/icons/nestly-512.png',
        sizes: '512x512',
        type: 'image/png',
        purpose: 'any maskable'
      }
    ]
  );
  assert.deepEqual(await pngDimensions('icons/nestly-192.png'), { width: 192, height: 192 });
  assert.deepEqual(await pngDimensions('icons/nestly-512.png'), { width: 512, height: 512 });
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
    assert.match(html, /src="\/pwa\.js" defer/, `${page} PWA lifecycle`);
  }
});

test('service worker installs only the versioned public fallback shell', async () => {
  const source = await text('sw.js');
  const harness = serviceWorkerHarness(source);
  let installPromise;

  harness.listeners.get('install')({
    waitUntil(value) {
      installPromise = Promise.resolve(value);
    }
  });
  await installPromise;

  assert.equal(harness.addedShells.length, 1);
  const shell = harness.addedShells[0];
  assert.ok(shell.includes('/offline.html'));
  assert.ok(shell.includes('/manifest.webmanifest'));
  assert.ok(shell.includes('/icons/nestly-512.png'));
  assert.ok(!shell.includes('/'));
  assert.ok(!shell.includes('/index.html'));
  assert.ok(!shell.includes('/join.html'));
  assert.doesNotMatch(source, /cache\.put\s*\(/);
  assert.doesNotMatch(shell.join('\n'), /supabase|runtime-config|customer-ui|brand-config/i);
});

test('cold offline navigation returns the self-contained fallback, not a broken app shell', async () => {
  const source = await text('sw.js');
  const harness = serviceWorkerHarness(source);
  const response = await dispatchFetch(
    harness.listeners.get('fetch'),
    request('https://www.nestly.asia/#/customer', { mode: 'navigate' })
  );

  assert.equal(response, harness.offlineResponse);
  assert.deepEqual(harness.matchedPaths, ['/offline.html']);
});

test('online navigation stays network-first and is never persisted by the service worker', async () => {
  const onlineResponse = Object.freeze({ kind: 'network-document' });
  let fetchCount = 0;
  const harness = serviceWorkerHarness(await text('sw.js'), {
    fetchImpl: async () => {
      fetchCount += 1;
      return onlineResponse;
    }
  });

  const response = await dispatchFetch(
    harness.listeners.get('fetch'),
    request('https://www.nestly.asia/#/wallet', { mode: 'navigate' })
  );

  assert.equal(response, onlineResponse);
  assert.equal(fetchCount, 1);
  assert.deepEqual(harness.matchedPaths, []);
});

test('authenticated, API, cross-origin and mutation requests bypass PWA caching', async () => {
  const harness = serviceWorkerHarness(await text('sw.js'));
  const fetchListener = harness.listeners.get('fetch');
  const cases = [
    request('https://www.nestly.asia/api/session'),
    request('https://www.nestly.asia/pwa.css', {
      headers: { has: (name) => name.toLowerCase() === 'authorization' }
    }),
    request('https://gadpooereceldfpfxsod.supabase.co/rest/v1/customers'),
    request('https://www.nestly.asia/pwa.css', { method: 'POST' })
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
    /@media\(max-width:720px\)[\s\S]+input,select,textarea\{font-size:16px!important\}/
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
