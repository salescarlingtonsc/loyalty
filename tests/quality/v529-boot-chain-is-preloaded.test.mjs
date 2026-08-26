import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/* nestly_v529 — the boot chain is fetched in parallel instead of one file at a time.
 *
 * Measured on production 26 Aug 2026, after v527. Four parser-blocking <script src> tags sit in
 * the body, and a parser-blocking script's bytes are not requested until the previous one has
 * finished downloading AND executing. The result was a staircase:
 *   brand-config 174->401 · runtime-config 490->557 · loader 558->622 · customer-ui 623->793
 *   · supabase 798->1057 · app-core 1065->1292
 * app-core.js — which every surface needs — did not begin downloading for a full second.
 *
 * A preload changes WHEN THE BYTES ARE FETCHED and nothing else: execution order, timing and
 * blocking semantics are still the parser's. That is why `defer` was not used instead — defer
 * moves execution to DOMContentLoaded, which would change when window.BRAND, the runtime config
 * and CustomerUI come into existence, on a chain whose order is load-bearing.
 *
 * THE FAILURE THIS FILE EXISTS TO CATCH: a preload href that drifts from its <script src> by even
 * one character — a bumped ?v= on one and not the other — silently fetches the file TWICE and
 * makes the page slower than before. So these assertions pair them up rather than counting them.
 */

const repo = new URL('../../', import.meta.url);
const source = readFileSync(new URL('app/index.html', repo), 'utf8');
const shipped = readFileSync(new URL('app/index.gen.html', repo), 'utf8');

const blockingScripts = (html) => {
  const body = html.slice(html.indexOf('<body'));
  return [...body.matchAll(/<script src="(\/[^"]+)"(?![^>]*\b(?:defer|async)\b)><\/script>/g)]
    .map((m) => m[1]);
};
const preloads = (html) => {
  const head = html.slice(0, html.indexOf('<body'));
  return [...head.matchAll(/<link rel="preload" as="script" href="([^"]+)">/g)].map((m) => m[1]);
};

for (const [label, html] of [['source', source], ['shipped', shipped]]) {
  test(`V529 every parser-blocking boot script is preloaded, exactly (${label})`, () => {
    const scripts = blockingScripts(html);
    const warmed = preloads(html);
    assert.ok(scripts.length >= 4, `expected the boot chain, found ${scripts.length}`);
    for (const src of scripts) {
      assert.ok(warmed.includes(src),
        `${src} blocks the parser but is not preloaded — everything after it waits for its round trip`);
    }
    for (const href of warmed) {
      assert.ok(html.includes(`<script src="${href}"`),
        `${href} is preloaded but no script tag uses that exact URL — the bytes are fetched and thrown away`);
    }
  });
}

test('V529 the preloads sit in the head, before the scripts they warm', () => {
  const headEnd = shipped.indexOf('<body');
  for (const href of preloads(shipped)) {
    assert.ok(shipped.indexOf(`href="${href}"`) < headEnd,
      'a preload after the tag it warms is pure waste');
  }
});

test('V529 the cross-origin CDN script is deliberately left alone', () => {
  /* It carries an SRI integrity hash with no crossorigin attribute. A preload whose CORS mode did
     not match would fetch 53 KB a second time — slower, not faster. It already gains from the
     staircase above it collapsing. */
  assert.match(shipped, /<script src="https:\/\/cdn\.jsdelivr\.net\/[^"]+" integrity="/,
    'the CDN tag is still SRI-guarded');
  assert.ok(!preloads(shipped).some((href) => href.startsWith('http')),
    'no cross-origin preload may be added without matching its CORS mode first');
});

test('V529 defer was not silently applied to the boot chain', () => {
  /* The order these four run in is load-bearing: brand-config defines window.BRAND, the runtime
     config loader reads it, customer-ui needs both. Deferring them would move all of that to
     DOMContentLoaded and is a behaviour change, not a performance one. */
  const body = shipped.slice(shipped.indexOf('<body'));
  for (const src of ['/brand-config.js', '/runtime-config.js?v=2',
    '/runtime-config-loader.js?v=2']) {
    assert.ok(body.includes(`<script src="${src}"></script>`),
      `${src} must stay a plain blocking script — its execution point is part of the contract`);
  }
});

test('V529 app-core is preloaded, and the stamper keeps the two fingerprints identical', () => {
  /* app-core.js is the biggest file on the critical path and, as a <script defer> in the body, its
     bytes were not requested until everything above it finished — 1,013 ms in, measured on
     production. The preload starts it with the first wave.
     The fingerprints MUST match. A preload one build behind its tag fetches 178 KB twice and is
     worse than having no preload at all, which is why scripts/quality/stamp-app-bundle.mjs owns
     both strings and rewrites them together. */
  const preload = shipped.match(/<link rel="preload" as="script" href="(\/app-core\.js\?b=[0-9a-f]{12})">/);
  const tag = shipped.match(/<script src="(\/app-core\.js\?b=[0-9a-f]{12})" defer><\/script>/);
  assert.ok(preload, 'the shipped document preloads app-core');
  assert.ok(tag, 'and still loads it as a deferred script');
  assert.equal(preload[1], tag[1],
    'the preload and the script tag must name the SAME build, or the file is downloaded twice');
});

test('V529 the stamper refuses a document whose core preload has gone missing', async () => {
  const { stampDocument } = await import('../../scripts/quality/stamp-app-bundle.mjs');
  const chunks = { core: 'a', auth: 'b', customer: 'c', business: 'd', i18n: 'e' };
  const withoutPreload = shipped.replace(
    /<link rel="preload" as="script" href="\/app-core\.js\?b=[0-9a-f]{12}">/, '');
  assert.throws(() => stampDocument(withoutPreload, chunks), /preload link/,
    'losing the preload silently would undo this change with nothing to notice it');
});
