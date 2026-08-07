import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const indexHtml = await read('app/index.html');
const appJs = await read('app/app.js');
const app = `${indexHtml}\n${appJs}`;

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const runtime = section(appJs, 'const CUSTOMER_THEME_KEY_V190', 'function setCustomerSurfaceDocumentV167');

function load({ stored = null, deviceDark = false } = {}) {
  const store = new Map(stored === null ? [] : [['peekaa.customer.theme', stored]]);
  const html = {
    attributes: new Map(),
    setAttribute(name, value) { this.attributes.set(name, value); },
    removeAttribute(name) { this.attributes.delete(name); }
  };
  const meta = { content: '', setAttribute(_, value) { this.content = value; } };
  const context = {
    localStorage: { getItem: (key) => store.has(key) ? store.get(key) : null, setItem: (key, value) => store.set(key, value) },
    matchMedia: () => ({ matches: deviceDark, addEventListener() {} }),
    document: { documentElement: html, querySelector: () => meta }
  };
  /* The source reads bare `localStorage`/`document`, which in a browser are globals; inject them
     as parameters so the harness exercises the real body rather than a rewritten copy. */
  const api = new Function('globalThis', 'localStorage', 'document', `${runtime}
    return {customerThemePreferenceV190,customerThemeIsDarkV190,applyCustomerThemeV190,setCustomerThemePreferenceV190};`)(
    context, context.localStorage, context.document);
  return { api, html, meta, store };
}

/* ------------------------------------------------------- beige is the default, not the device */

test('the customer surface is beige even on a phone in dark mode', () => {
  const { api, html, meta } = load({ deviceDark: true });
  assert.equal(api.customerThemePreferenceV190(), 'light');
  api.applyCustomerThemeV190();
  assert.equal(html.attributes.has('data-customer-theme'), false,
    'no attribute means the business palette, which is the point');
  assert.equal(meta.content, '#F4F2EE', 'the browser chrome follows the surface, not the device');
});

test('the dark tokens are opt-in only — nothing keys off the device any more', () => {
  assert.doesNotMatch(indexHtml, /@media\(prefers-color-scheme:\s*dark\)/,
    'a customer must not be flipped to dark by their phone');
  assert.match(indexHtml, /html\[data-customer-theme="dark"\] \.customer-surface,/);
  assert.match(indexHtml, /html\[data-customer-theme="dark"\]\[data-customer-surface="true"\] body\{background:#0F1115\}/);
  // the sheets that live outside .customer-surface must still join the dark scope
  assert.match(indexHtml, /html\[data-customer-theme="dark"\] \.customer-offer-detail-modal \.modal-card/);
  assert.match(indexHtml, /html\[data-customer-theme="dark"\] \.customer-business-detail-modal \.modal-card/);
  // :is() groups must have survived the re-gating intact
  assert.match(indexHtml, /html\[data-customer-theme="dark"\] \.customer-surface\.customer-surface :is\(input,select,textarea,/);
});

/* --------------------------------------------------------------------------- the three choices */

test('dark is applied only when the customer asks for it', () => {
  const { api, html, meta } = load({ stored: 'dark', deviceDark: false });
  api.applyCustomerThemeV190();
  assert.equal(html.attributes.get('data-customer-theme'), 'dark');
  assert.equal(meta.content, '#0F1115');
});

test('"match my device" is the only setting that reads the phone', () => {
  const dark = load({ stored: 'device', deviceDark: true });
  dark.api.applyCustomerThemeV190();
  assert.equal(dark.html.attributes.get('data-customer-theme'), 'dark');

  const light = load({ stored: 'device', deviceDark: false });
  light.api.applyCustomerThemeV190();
  assert.equal(light.html.attributes.has('data-customer-theme'), false);
});

test('an unknown or unreadable preference falls back to beige', () => {
  const junk = load({ stored: 'neon', deviceDark: true });
  assert.equal(junk.api.customerThemePreferenceV190(), 'light');
  const saved = load({ deviceDark: true });
  assert.equal(saved.api.setCustomerThemePreferenceV190('nonsense'), 'light');
  assert.equal(saved.store.get('peekaa.customer.theme'), 'light');
  assert.equal(saved.html.attributes.has('data-customer-theme'), false);
});

test('choosing a theme persists it and applies it in the same step', () => {
  const { api, html, store } = load({ deviceDark: false });
  api.setCustomerThemePreferenceV190('dark');
  assert.equal(store.get('peekaa.customer.theme'), 'dark');
  assert.equal(html.attributes.get('data-customer-theme'), 'dark');
  api.setCustomerThemePreferenceV190('light');
  assert.equal(html.attributes.has('data-customer-theme'), false);
});

/* ----------------------------------------------------------------------- where you change it */

test('Appearance lives in the customer profile with all three choices', () => {
  assert.match(app, /<section class="card" id="customerAppearance"/);
  assert.match(app, /<h2>Appearance<\/h2>/);
  assert.match(app, /id="customerTheme-\$\{value\}"/, 'each choice renders its own labelled radio');
  for (const [value, label] of [['light', 'Light'], ['dark', 'Dark'], ['device', 'Match my device']]) {
    assert.ok(app.includes(`['${value}','${label}',`), `${label} must be offered as the ${value} choice`);
  }
  assert.match(app, /role="radiogroup" aria-label="Appearance"/);
  assert.match(app, /Beige, like the business app/);
  assert.match(app, /setCustomerThemePreferenceV190\(option\.value\)/);
  assert.match(app, /CUI\.announce\(option\.value==='dark'\?'Dark appearance on'/,
    'a screen-reader user must be told the surface changed');
});

test('the surface applies the stored choice every time it renders', () => {
  assert.match(appJs, /function setCustomerSurfaceDocumentV167\(\)\{[\s\S]{0,200}applyCustomerThemeV190\(\)/);
  assert.match(appJs, /addEventListener\?\.\('change',\(\)=>\{\s*if\(customerThemePreferenceV190\(\)==='device'\)applyCustomerThemeV190\('device'\)/,
    'a device-following customer must track a change made while the app is open');
});
