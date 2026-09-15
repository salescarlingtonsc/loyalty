/* nestly_v954 — the customer wallet gets a localiser, and this runs it.
 *
 * Until this wave the wallet had no DOM localisation at all: ct() translates 152 strings at the
 * call site and the other ~500 sentences the customer reads were written as literals, so choosing
 * 简体中文 changed the picker and nothing else. localizeCustomerSubtreeV954 is the v97 walker's
 * twin — the customer's locale, the customer's root, the same reviewed catalogue.
 *
 * These EXECUTE both walkers, lifted verbatim out of app/app.js, against tests/support/mini-dom.mjs.
 * The first test is the measuring tool's own check: the SHIPPED workspace walker is run through the
 * same DOM and has to show behaviour it is already known to have. If the mini DOM were wrong, that
 * fails before any claim about the customer walker is made.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { element, Node } from '../support/mini-dom.mjs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

const block = (start, end) => {
  const from = app.indexOf(start);
  assert.ok(from >= 0, `missing block start: ${start}`);
  const to = app.indexOf(end, from + start.length);
  assert.ok(to > from, `missing block end: ${end}`);
  return app.slice(from, to);
};

const WALKERS = [
  block('function isWorkspaceDynamicNodeV97(element){', 'function observeWorkspaceLocalizationV97(){'),
  block('const workspaceTranslationV97=(source,locale=workspaceLocale)=>', '\n/*'),
].join('\n');

/* Two entries in the real catalogue and one merchant-shaped string that is NOT in it. */
const CATALOG = {
  'zh-CN': { 'Show fallback code': '显示备用代码', 'Cancel redemption': '取消兑换', 'Enter your code': '输入您的代码' },
  ms: { 'Show fallback code': 'Tunjukkan kod sandaran' }
};

function runtime({ workspaceLocale = 'en', customerLocale = 'en', root }) {
  const context = vm.createContext({
    Node, root, workspaceLocale, customerLocale,
    WORKSPACE_COPY_V97: {}, WORKSPACE_GENERATED_COPY_V97: CATALOG,
    HTMLOptionElement: class HTMLOptionElement {},
    Element: Object.getPrototypeOf(element('p', {})).constructor,
    globalThis: { document: null, MutationObserver: null },
    localizeWorkspaceTemplateV97: () => {},
    localizeWorkspaceTemplateAttributesV97: () => {},
    workspaceTemplateValuesV97: new WeakMap(),
    workspaceTextSourcesV97: new WeakMap(),
    workspaceAttributeSourcesV97: new WeakMap()
  });
  vm.runInContext(`${WALKERS}
    __exports={localizeWorkspaceSubtreeV97,localizeCustomerSubtreeV954,
      setWorkspaceLocale:v=>{workspaceLocale=v},setCustomerLocale:v=>{customerLocale=v}};`, context);
  return context.__exports;
}

test('the mini DOM is a faithful enough measuring tool: the SHIPPED workspace walker behaves on it as it is known to', () => {
  const inMain = element('p', {}, 'Show fallback code');
  const merchant = element('p', { 'data-merchant-content': '' }, 'Show fallback code');
  const preview = element('div', { class: 'wallet-shell' }, element('p', {}, 'Show fallback code'));
  const root = element('div', {}, element('div', { class: 'shell' },
    element('div', { class: 'main' }, inMain, merchant, preview)));

  runtime({ workspaceLocale: 'zh-CN', root }).localizeWorkspaceSubtreeV97(root);

  assert.equal(inMain.textContent, '显示备用代码', 'a plain node inside .main is translated');
  assert.equal(merchant.textContent, 'Show fallback code', 'merchant content is left alone');
  assert.equal(preview.textContent, 'Show fallback code',
    '.wallet-shell is the owner’s customer-interface preview — the workspace walker never claims it');
});

test('the customer walker translates the wallet into the CUSTOMER’s language', () => {
  const line = element('p', {}, 'Show fallback code');
  const root = element('div', {}, element('div', { class: 'wallet-shell customer-shell customer-surface' }, line));

  runtime({ customerLocale: 'zh-CN', root }).localizeCustomerSubtreeV954(root);
  assert.equal(line.textContent, '显示备用代码');
});

test('the owner’s language and the customer’s are two settings, and neither drives the other', () => {
  const line = element('p', {}, 'Cancel redemption');
  const root = element('div', {}, element('div', { class: 'customer-surface' }, line));

  /* Owner in Malay, customer in Chinese: the wallet must follow the customer. */
  runtime({ workspaceLocale: 'ms', customerLocale: 'zh-CN', root }).localizeCustomerSubtreeV954(root);
  assert.equal(line.textContent, '取消兑换');
});

test('a locale with no catalogue leaves the wallet in English rather than blanking it', () => {
  const line = element('p', {}, 'Cancel redemption');
  const root = element('div', {}, element('div', { class: 'customer-surface' }, line));
  runtime({ customerLocale: 'ta', root }).localizeCustomerSubtreeV954(root);
  assert.equal(line.textContent, 'Cancel redemption', 'Tamil is declared but uncatalogued — it degrades to English');
});

test('merchant words stay the merchant’s, in every locale', () => {
  const shopName = element('b', { 'data-merchant-content': '' }, 'Cancel redemption');
  const rewardName = element('span', { class: 'customer-link' }, 'Cancel redemption');
  const root = element('div', {}, element('div', { class: 'customer-surface' }, shopName, rewardName));

  runtime({ customerLocale: 'zh-CN', root }).localizeCustomerSubtreeV954(root);
  assert.equal(shopName.textContent, 'Cancel redemption', 'a business’s own words are not the product’s to translate');
  assert.equal(rewardName.textContent, 'Cancel redemption');
});

test('the customer walker refuses to run while the workspace shell is up', () => {
  /* The owner previewing the customer interface is looking at the workspace, in the workspace's
     language. Two walkers claiming one node is how a preview starts disagreeing with itself. */
  const line = element('p', {}, 'Show fallback code');
  const root = element('div', {},
    element('div', { class: 'shell' }, element('div', { class: 'main' },
      element('div', { class: 'customer-surface' }, line))));

  runtime({ customerLocale: 'zh-CN', root }).localizeCustomerSubtreeV954(root);
  assert.equal(line.textContent, 'Show fallback code');
});

test('switching language twice translates from the English source, not from the last translation', () => {
  const line = element('p', {}, 'Show fallback code');
  const root = element('div', {}, element('div', { class: 'customer-surface' }, line));
  const walker = runtime({ customerLocale: 'zh-CN', root });

  walker.localizeCustomerSubtreeV954(root);
  assert.equal(line.textContent, '显示备用代码');
  walker.setCustomerLocale('ms');
  walker.localizeCustomerSubtreeV954(root);
  assert.equal(line.textContent, 'Tunjukkan kod sandaran', 'ms is looked up from the English, not from 中文');
  walker.setCustomerLocale('en');
  walker.localizeCustomerSubtreeV954(root);
  assert.equal(line.textContent, 'Show fallback code', 'and English comes back exactly');
});

test('the four spoken and typed-into attributes are translated too', () => {
  const input = element('input', { placeholder: 'Enter your code', 'aria-label': 'Cancel redemption' });
  const button = element('button', { title: 'Show fallback code', 'data-label': 'Cancel redemption' });
  const root = element('div', {}, element('div', { class: 'customer-surface' }, input, button));

  runtime({ customerLocale: 'zh-CN', root }).localizeCustomerSubtreeV954(root);
  assert.equal(input.getAttribute('placeholder'), '输入您的代码');
  assert.equal(input.getAttribute('aria-label'), '取消兑换');
  assert.equal(button.getAttribute('title'), '显示备用代码');
  assert.equal(button.getAttribute('data-label'), '取消兑换');
});

test('the wallet is localised where it is rendered, and watched for what arrives after', () => {
  /* renderCustomerShell is the one place every customer view writes root.innerHTML. */
  const shell = block('function renderCustomerShell({', '\nfunction focusCustomerRoute()');
  assert.match(shell, /localizeCustomerSubtreeV954\(\);/, 'the wallet is localised when it is drawn');
  assert.match(shell, /observeCustomerLocalizationV954\(\);/, 'and what is added later — a dialog, the QR sheet — is caught');
  /* The tables are ~776KB and only fetched for a non-English reader; the wallet must ask for them
     the same way the workspace does, or a 中文 customer walks the DOM against an absent catalogue. */
  assert.match(app, /if\(customerLocale!=='en'\)await loadWorkspaceI18nV185\(\);/);
  assert.equal(app.split("if(customerLocale!=='en')await loadWorkspaceI18nV185();").length - 1, 2,
    'both the first profile load and a later language change fetch them');
});

test('there is still exactly one reader of the translation tables', () => {
  /* scripts/quality/split-app-bundle.mjs enforces this at build time — the typeof guard that lets
     any surface translate before the i18n chunk lands is written once, in one function. */
  const readers = [...app.matchAll(/WORKSPACE_GENERATED_COPY_V97\s*\[/g)];
  assert.equal(readers.length, 1, 'the generated table is indexed in one place');
  assert.match(app, /const customerTranslationV954=source=>workspaceTranslationV97\(source,customerLocale\);/,
    'the customer walker asks that one reader for the customer’s locale');
});
