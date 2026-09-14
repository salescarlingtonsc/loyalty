import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* nestly_v896 — the merchant half of the auto-mapping work (nestly_v895 is the migration that
   maps a new service to a category on the way in, and that extends
   get_service_mapping_board_v1's payload).

   Two things have to be true of this UI and neither can be established by grepping for a class
   name, so every assertion below either EXECUTES the markup helper or executes the exact template
   expression lifted out of the page:
     1. it says what Peekaa decided — Likely/Possible beside a suggestion, "auto" beside a category
        nobody picked, a count on the bulk-accept button;
     2. it degrades to the pre-v895 screen field by field. A server that never got the migration
        sends no suggested_confident, no mapped_method and no suggestions block, and the screen it
        produces has to be the one that shipped in v650 — not a page covered in "Possible" pills
        that the server never claimed. */

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const registry = JSON.parse(readFileSync(join(root, 'docs', 'design', 'ps0', 'writer-registry.json'), 'utf8'));

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* A top-level `function name(...){` … closing `}` in column 0. */
function extractFunction(src, name) {
  const m = new RegExp(`^(?:async )?function ${name}\\(`, 'm').exec(src);
  assert.ok(m, `missing function ${name}`);
  const acc = [];
  for (const line of src.slice(m.index).split('\n')) { acc.push(line); if (line === '}') return acc.join('\n'); }
  throw new Error(`no close for ${name}`);
}
/* The same, for a function nested one level inside a page function (closing `  }`). */
function extractNestedFunction(src, name, indent = '  ') {
  const m = new RegExp(`^${indent}(?:async )?function ${name}\\(`, 'm').exec(src);
  assert.ok(m, `missing nested function ${name}`);
  const acc = [];
  for (const line of src.slice(m.index).split('\n')) { acc.push(line); if (line === `${indent}}`) return acc.join('\n'); }
  throw new Error(`no close for ${name}`);
}

const helpers = vm.createContext({ esc });
for (const name of ['serviceMappingSuggestionCountV896', 'serviceMappingAcceptAllLabelV896',
  'serviceMappingSuggestPillV896', 'serviceMappingAutoPillV896', 'servicesCategoryChipV896']) {
  vm.runInContext(extractFunction(app, name), helpers);
}
const call = (expr) => vm.runInContext(expr, helpers);

const boardPage = app.slice(app.indexOf('async function serviceMappingBoardPage(){'),
  app.indexOf('/* ---------- reports ---------- */'));
assert.ok(boardPage.length > 1000 && boardPage.length < 20000, 'board page slice looks wrong');
const servicesPage = extractFunction(app, 'servicesPage');
assert.ok(servicesPage.length > 1000, 'services page slice looks wrong');

/* ---------- the suggestion pills ---------- */

test('v896: a confident suggestion is Likely, an uncertain one is Possible', () => {
  const likely = call(`serviceMappingSuggestPillV896(${JSON.stringify({
    suggested_node_key: 'beauty.facial', suggested_confident: true,
    suggested_keyword: 'facial', suggested_reason: 'own_pack_unique',
  })})`);
  assert.match(likely, /class="svcmap-pill-v896 is-likely"/);
  assert.match(likely, />Likely</);
  assert.match(likely, /title="matched &#39;facial&#39;"/, 'the matched word is the hint, HTML-escaped');
  assert.match(likely, /data-merchant-content/,
    'the hint quotes the merchant’s own word, so v97 must leave the element untranslated');

  const possible = call(`serviceMappingSuggestPillV896(${JSON.stringify({
    suggested_node_key: 'wellness.massage', suggested_confident: false,
    suggested_keyword: 'spa', suggested_reason: 'cross_pack',
  })})`);
  assert.match(possible, /class="svcmap-pill-v896 is-possible"/);
  assert.match(possible, />Possible</);
  assert.match(possible, /title="matched &#39;spa&#39;"/);
  assert.doesNotMatch(possible, />Likely</);
});

test('v896: no suggestion, or a server that never stated confidence, draws no pill at all', () => {
  assert.equal(call(`serviceMappingSuggestPillV896({suggested_confident:true})`), '',
    'confidence without a suggestion is nothing to show');
  assert.equal(call(`serviceMappingSuggestPillV896(null)`), '');
  assert.equal(call(`serviceMappingSuggestPillV896({suggested_node_key:'beauty.facial'})`), '',
    'a pre-v895 payload has no suggested_confident and must render exactly as v650 did');
  assert.equal(call(`serviceMappingSuggestPillV896({suggested_node_key:'x',suggested_confident:'true'})`), '',
    'only a real boolean counts — a string is not a claim this UI may make on the server’s behalf');
});

test('v896: a suggestion with no keyword gets a pill but no invented hint', () => {
  for (const row of [
    { suggested_node_key: 'a', suggested_confident: true },
    { suggested_node_key: 'a', suggested_confident: true, suggested_keyword: '   ' },
    { suggested_node_key: 'a', suggested_confident: true, suggested_keyword: null },
  ]) {
    const pill = call(`serviceMappingSuggestPillV896(${JSON.stringify(row)})`);
    assert.match(pill, />Likely</, 'the pill itself still stands');
    assert.doesNotMatch(pill, /title=/, 'an empty or made-up hint is worse than none');
    assert.doesNotMatch(pill, /data-merchant-content/, 'and with no merchant word in it, nothing is pinned');
  }
});

/* ---------- the "auto" mark ---------- */

test('v896: only an auto_ mapping is marked auto; a chosen one is not', () => {
  for (const method of ['auto_keyword', 'auto_keyword_backfill']) {
    const pill = call(`serviceMappingAutoPillV896(${JSON.stringify({ mapped_method: method })})`);
    assert.match(pill, /class="svcmap-pill-v896 is-auto"/, `${method} must be marked`);
    assert.match(pill, />auto</);
    assert.match(pill, /title="Peekaa chose this category/);
  }
  for (const method of ['manual', 'accepted_suggestions', null, undefined, '', 'automatic']) {
    assert.equal(call(`serviceMappingAutoPillV896(${JSON.stringify({ mapped_method: method })})`), '',
      `${String(method)} is not an automatic mapping`);
  }
  assert.equal(call(`serviceMappingAutoPillV896({})`), '', 'a pre-v895 row carries no mapped_method');
  assert.equal(call(`serviceMappingAutoPillV896(null)`), '');
});

/* ---------- the bulk-accept button ---------- */

test('v896: the Accept-all label counts both kinds of suggestion, and reads singular at one', () => {
  assert.equal(call(`serviceMappingAcceptAllLabelV896({suggestions:{confident:3,possible:1}})`), 'Accept 4 suggestions');
  assert.equal(call(`serviceMappingAcceptAllLabelV896({suggestions:{confident:1,possible:0}})`), 'Accept 1 suggestion');
  assert.equal(call(`serviceMappingAcceptAllLabelV896({suggestions:{confident:0,possible:1}})`), 'Accept 1 suggestion');
});

test('v896: nothing to accept, or a server that sends no suggestions block, draws no button', () => {
  assert.equal(call(`serviceMappingAcceptAllLabelV896({suggestions:{confident:0,possible:0}})`), '');
  assert.equal(call(`serviceMappingAcceptAllLabelV896({services:[],nodes:[]})`), '',
    'a pre-v895 payload has no suggestions key — the header stays as it was');
  assert.equal(call(`serviceMappingAcceptAllLabelV896(null)`), '');
  assert.equal(call(`serviceMappingAcceptAllLabelV896({suggestions:null})`), '');
  assert.equal(call(`serviceMappingSuggestionCountV896({services:[]})`), null,
    'absent is null, not zero: the two are different states even though both hide the button');
  assert.equal(call(`serviceMappingAcceptAllLabelV896({suggestions:{confident:'x',possible:2}})`), 'Accept 2 suggestions',
    'a junk half is ignored rather than turning the whole label into NaN');
});

test('v896: the board draws the button from that label, for writers only, and busies it on click', () => {
  assert.match(boardPage, /const acceptAllLabelV896=canWrite\?serviceMappingAcceptAllLabelV896\(board\):''/,
    'a read-only actor never sees a write button');
  assert.match(boardPage, /acceptAllLabelV896\?`<button type="button" class="btn sm" id="svcMapAcceptAllV896">\$\{esc\(acceptAllLabelV896\)\}<\/button>`:''/);
  assert.match(boardPage, /CUI\.setButtonBusy\(acceptAllV896,\{busy:true,label:'Applying…'\}\)/);
  assert.match(boardPage, /if\(error\)\{CUI\.setButtonBusy\(acceptAllV896,\{busy:false\}\)/,
    'a refusal gives the button back');
  assert.match(boardPage, /toast\('Suggestions applied'\);\s*\n\s*await loadBoard\(\);/,
    'the board is re-read from the server rather than patched optimistically');
});

test('v896: the bulk accept calls the v895 RPC with p_only_confident:false, from one call site', () => {
  assert.match(boardPage,
    /sb\.rpc\('accept_service_mapping_suggestions_v1',\{p_business:S\.biz\.id,p_only_confident:false\}\)/);
  assert.equal((app.match(/sb\.rpc\('accept_service_mapping_suggestions_v1'/g) || []).length, 1,
    'exactly one call site — the board header');
});

/* ---------- the board's row markup ---------- */

test('v896: the row markup asks both helpers, and the select is still the way to change a mapping', () => {
  assert.match(boardPage,
    /<td data-label="Mapped to">\$\{current\?`\$\{esc\(current\)\}\$\{serviceMappingAutoPillV896\(service\)\}`:'<span class="muted">—<\/span>'\}<\/td>/);
  assert.match(boardPage, /\$\{esc\(suggestedLabel\)\}\$\{serviceMappingSuggestPillV896\(service\)\}\$\{canWrite\?` <button class="btn ghost sm" type="button" data-accept-suggestion=/,
    'the pill sits between the suggested label and the per-row Accept, which stays');
  assert.match(boardPage, /<select data-service-select="\$\{esc\(service\.service_id\)\}"/);
});

test('v896: the subtitle says Peekaa maps services itself; the empty state is untouched', () => {
  assert.match(boardPage, /subtitle:'Peekaa maps new services automatically when the name is clear\. Check the rest here\.'/);
  assert.match(boardPage, /CUI\.emptyState\(\{iconName:'services',title:'No services yet',body:'Add services first, then map them to categories here\.'\}\)/);
});

/* ---------- the Services catalogue chip ---------- */

test('v896: the chip names the category, and says so plainly when there is none', () => {
  assert.match(call(`servicesCategoryChipV896('Facial')`), /<span class="svc-cat-chip-v896">Facial<\/span>/);
  assert.match(call(`servicesCategoryChipV896('')`), /<span class="svc-cat-chip-v896 is-none">Not mapped<\/span>/);
  assert.match(call(`servicesCategoryChipV896(undefined)`), /is-none">Not mapped</);
  assert.match(call(`servicesCategoryChipV896('   ')`), /is-none">Not mapped</);
  assert.match(call(`servicesCategoryChipV896('Hair & Nails')`), />Hair &amp; Nails</);
});

/* The name cell's category expression, lifted verbatim out of renderSvc and executed. */
const cellExpr = (() => {
  const from = servicesPage.indexOf('${serviceCategoryReadyV896?');
  const to = servicesPage.indexOf('${photoAction?', from);
  assert.ok(from > 0 && to > from, 'the category expression is no longer in the service name cell');
  return servicesPage.slice(from, to);
})();

function nameCell({ boardResult, canWrite = true, serviceId = 'svc-1' }) {
  const ctx = vm.createContext({ esc });
  vm.runInContext(extractFunction(app, 'servicesCategoryChipV896'), ctx);
  vm.runInContext('var serviceCategoryMapV896=new Map(),serviceCategoryReadyV896=false;', ctx);
  vm.runInContext(extractNestedFunction(app, 'applyServiceCategoriesV896'), ctx);
  const applied = vm.runInContext(`applyServiceCategoriesV896(${JSON.stringify(boardResult)})`, ctx);
  ctx.canWrite = canWrite;
  ctx.s = { id: serviceId };
  return { applied, html: vm.runInContext('`' + cellExpr + '`', ctx) };
}

const boardOk = {
  data: {
    nodes: [{ node_key: 'beauty.facial', label: 'Facial' }],
    services: [
      { service_id: 'svc-1', name: 'Signature Facial', node_key: 'beauty.facial', mapped_method: 'auto_keyword' },
      { service_id: 'svc-2', name: 'Mystery Thing', node_key: null },
    ],
  },
};

test('v896: a mapped service shows its category, an unmapped one shows Not mapped', () => {
  const mapped = nameCell({ boardResult: boardOk, serviceId: 'svc-1' });
  assert.equal(mapped.applied, true);
  assert.match(mapped.html, /<span class="svc-cat-chip-v896">Facial<\/span>/);
  assert.match(mapped.html, /<a class="svc-cat-change-v896" href="#\/servicemapping">Change<\/a>/);

  const unmapped = nameCell({ boardResult: boardOk, serviceId: 'svc-2' });
  assert.match(unmapped.html, /is-none">Not mapped</);

  const unknownRow = nameCell({ boardResult: boardOk, serviceId: 'svc-not-on-the-board' });
  assert.match(unknownRow.html, /is-none">Not mapped</, 'a row the board did not return is not mapped');
});

test('v896: a node the board did not describe falls back to its key rather than vanishing', () => {
  const cell = nameCell({
    boardResult: { data: { nodes: [], services: [{ service_id: 'svc-1', node_key: 'beauty.facial' }] } },
  });
  assert.match(cell.html, />beauty\.facial</);
});

test('v896: a read-only actor sees the category but is offered no way to change it', () => {
  const cell = nameCell({ boardResult: boardOk, canWrite: false });
  assert.match(cell.html, />Facial</);
  assert.doesNotMatch(cell.html, /svc-cat-change-v896/);
});

test('v896: a failed board read leaves the catalogue row exactly as it was — no chip, no claim', () => {
  for (const boardResult of [
    { error: { message: 'permission denied for function get_service_mapping_board_v1' } },
    { data: null },
    { data: { nodes: [] } },
    {},
  ]) {
    const cell = nameCell({ boardResult });
    assert.equal(cell.applied, false, 'a read that answered nothing is not an answer');
    assert.equal(cell.html, '', 'nothing is drawn — never a page of "Not mapped"');
  }
});

test('v896: the board read rides alongside the page’s existing loads and cannot break them', () => {
  assert.match(servicesPage,
    /const \[servicesResult,mediaMap,branchesResultV613,serviceBranchesResultV613,mappingResultV896\]=await Promise\.all\(\[/,
    'one Promise.all, not a second serial round trip');
  assert.match(servicesPage, /readServiceCategoriesV896\(\)\n\s*\]\);\n\s*applyServiceCategoriesV896\(mappingResultV896\);/);
  assert.match(servicesPage, /try\{return await sb\.rpc\('get_service_mapping_board_v1',\{p_business:S\.biz\.id\}\)\}\s*\n\s*catch\(error\)\{return \{error\}\}/,
    'a thrown read is caught here, so Promise.all can never reject and empty the catalogue');
  assert.equal((app.match(/sb\.rpc\('get_service_mapping_board_v1'/g) || []).length, 2,
    'two call sites: the board page, and this one extra read on Services');
});

/* ---------- the add-service toast ---------- */

const addFlow = (() => {
  const from = servicesPage.indexOf("if(canWrite)$('sadd').onclick=");
  const to = servicesPage.indexOf("if(canWrite&&$('openServiceForm'))", from);
  assert.ok(from > 0 && to > from, 'the add-service handler moved');
  return servicesPage.slice(from, to);
})();

test('v896: adding a service re-reads the board once and says when Peekaa mapped it', () => {
  assert.match(addFlow, /const mappingReReadV896=applyServiceCategoriesV896\(await readServiceCategoriesV896\(\)\);/);
  assert.match(addFlow, /if\(!isCurrent\(\)\)return;/, 'the re-read is awaited, so the route is re-checked after it');
  assert.match(addFlow,
    /toast\(mappingReReadV896&&serviceCategoryMapV896\.get\(data&&data\.id\)\?'Service added and mapped automatically':'Service added'\)/,
    'the new toast only fires when the server actually came back with a category for THIS service');
  assert.equal((addFlow.match(/readServiceCategoriesV896\(\)/g) || []).length, 1, 'one re-read, not a poll');
});

/* ---------- house rules ---------- */

/* Every toast(...) argument in a slice, read to its own matching close paren so a ternary with
   nested calls inside it is captured whole rather than truncated at the first ")". */
function toastArguments(slice) {
  const args = [];
  for (const match of slice.matchAll(/\btoast\(/g)) {
    let depth = 1, i = match.index + match[0].length;
    const from = i;
    while (i < slice.length && depth > 0) {
      const ch = slice[i];
      if (ch === '(') depth += 1;
      else if (ch === ')') depth -= 1;
      i += 1;
    }
    assert.equal(depth, 0, 'unbalanced toast(');
    args.push(slice.slice(from, i - 1));
  }
  return args;
}

test('v896: every toast on these two screens is a literal, with nothing interpolated into it', () => {
  const added = [...toastArguments(boardPage), ...toastArguments(addFlow)];
  assert.ok(added.length >= 6, `expected the screens' toasts to be found, saw ${added.length}`);
  for (const arg of added) {
    assert.doesNotMatch(arg, /\$\{/, `toast argument interpolates: ${arg}`);
    assert.doesNotMatch(arg, /`/, `toast argument is a template literal: ${arg}`);
  }
  assert.ok(added.includes("'Suggestions applied'"), 'the bulk-accept toast is the agreed literal');
  assert.ok(added.includes("'Those suggestions could not be applied.'"), 'and its refusal is one too');
  assert.ok(added.some((a) => a.includes("'Service added and mapped automatically'") && a.includes("'Service added'")),
    'the add toast chooses between two literals');
});

test('v896: the new write RPC is registered, with its gate, before it can be called', () => {
  const entry = registry.allowlist.find((a) => a.id === 'browser.rpc:app/app.js:accept_service_mapping_suggestions_v1');
  assert.ok(entry, 'accept_service_mapping_suggestions_v1 must be curated in docs/design/ps0/writer-registry.json');
  assert.match(entry.reason, /WRITER/, 'it is recorded as a writer, not as a reader');
  assert.match(entry.reason, /services-module-WRITE gated/, 'its gate is stated');
  assert.match(entry.reason, /SECURITY DEFINER/);
  assert.match(entry.reason, /nestly_v896/, 'the version that wired the call site is named');
  assert.ok(registry.allowlist.some((a) => a.id === 'browser.rpc:app/app.js:get_service_mapping_board_v1'),
    'the reader the Services page now also calls stays registered');
});

test('v896: the styles are scoped to the new marks and restyle nothing shared', () => {
  const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');
  for (const selector of ['.svcmap-pill-v896', '.svcmap-pill-v896.is-likely', '.svcmap-pill-v896.is-possible',
    '.svcmap-pill-v896.is-auto', '.svc-cat-chip-v896', '.svc-cat-chip-v896.is-none', '.svc-cat-change-v896']) {
    assert.ok(html.includes(`${selector}{`) || html.includes(`${selector}:hover{`),
      `missing scoped rule for ${selector}`);
  }
});
