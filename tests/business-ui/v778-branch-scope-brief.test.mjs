/* NESTLY v778 — the Owner brief says which branch it is a report on, and compares them.
 *
 * Scope line   · get_ci_branch_directory_v1 (branches.code, nestly_v777)
 * Block L      · "Your branches side by side" · get_ci_branch_comparison_v1
 *
 * Same posture as tests/business-ui/v771-owner-brief.test.mjs and v774-owner-brief-readers:
 * ownerBriefHtmlV771 is a pure top-level function taking one plain object, so the brief is
 * EXECUTED here against fixtures shaped like the reader's real output rather than asserted by
 * grepping source. The fixtures follow the v777 contract: every share is a rate block
 * {numerator, denominator, pct} whose pct is NULL — never 0.0 — when the subgroup sits under the
 * shared evidence floor, and branches the caller may not see are COUNTED in branches_hidden
 * rather than listed.
 *
 * Three rules are tested as rules. A comparison of one branch is not a comparison, so the block
 * is absent rather than a one-row ranking. A branch that is selected has already been named by
 * the scope line, so the block is absent there too. And a withheld percent stays withheld, with
 * its base still printed — this is the one block where a rounded zero would read as a verdict
 * about the branch that scored it.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const START = 'function ownerBriefHtmlV771(brief){';
const fnStart = app.indexOf(START);
assert.ok(fnStart > -1, 'ownerBriefHtmlV771 must be a top-level function in app/app.js');
const fnEnd = app.indexOf('\n}', fnStart) + 2;
assert.ok(fnEnd > fnStart, 'ownerBriefHtmlV771 must close at column zero');
const block = app.slice(fnStart, fnEnd);

function render(brief) {
  const sandbox = {
    esc: (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'),
    money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2),
    walletDate: (v) => `WD:${v}`,
    CUI: { icon: () => '<svg aria-hidden="true"></svg>' },
    S: { biz: { currency: 'SGD' }, myRole: 'owner' }
  };
  const context = vm.createContext(sandbox);
  context.__exports = {};
  vm.runInContext(`${block}\n__exports.brief=ownerBriefHtmlV771;`, context);
  return context.__exports.brief(brief);
}

const textOf = (html) => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
const sectionOf = (html, className) => {
  const at = html.indexOf(`class="${className}"`);
  if (at < 0) return '';
  const open = html.lastIndexOf('<section', at);
  const close = html.indexOf('</section>', at);
  return html.slice(open, close + '</section>'.length);
};
const rowsOf = (section, label) =>
  (section.match(new RegExp(`<td data-label="${label}">[\\s\\S]*?</td>`, 'g')) || []).map(textOf);

const OK = { n: 8, floor: 5, status: 'ok' };
const LOW = { n: 2, floor: 5, status: 'insufficient' };

/* ==================================================================================================
   Fixtures — the v777 contract shape.

   Firm: 50 valid visits, 164000 recorded, 26 customers, across three visible branches and two the
   caller may not see. B01 has 20 of the 50 visits (40%) and 74000 of the takings (45%).
   ================================================================================================== */

const rate = (numerator, denominator, pct) => ({ numerator, denominator, pct });

const BRANCH_ONE = {
  branch: { id: 'br-1', code: 'B01', name: 'Orchard', is_default: true },
  visits: 20, revenue_cents: 74000, customers: 12, new_customers: 4,
  share_of_visits: rate(20, 50, 40.0),
  share_of_revenue: rate(74000, 164000, 45.1),
  gender: [
    { gender: 'female', customers: 6, share: rate(6, 8, 75.0) },
    { gender: 'male', customers: 2, share: rate(2, 8, null) }
  ],
  unknown_gender: { customers: 4 },
  age_bands: [
    { age_band: '25_30', customers: 5, share: rate(5, 8, 62.5) },
    { age_band: '41_50', customers: 3, share: rate(3, 8, null) }
  ],
  unknown_age: { customers: 4 },
  coverage: { gender_known: rate(8, 12, 66.7), age_known: rate(8, 12, 66.7) },
  evidence: { gender: OK, age_band: OK },
  top_age_band: '25_30',
  busiest_weekday: { label: 'Monday', per_occurrence: 5.0 },
  slowest_weekday: { label: 'Wednesday', per_occurrence: 1.5 },
  top_item: { item_name: 'facial', item_type: 'service', revenue_cents: 153000, buyers: 9 }
};

const BRANCH_TWO = {
  branch: { id: 'br-2', code: 'B02', name: 'Tampines', is_default: false },
  visits: 18, revenue_cents: 56000, customers: 9, new_customers: 2,
  share_of_visits: rate(18, 50, 36.0),
  share_of_revenue: rate(56000, 164000, 34.1),
  gender: [{ gender: 'female', customers: 3, share: rate(3, 4, null) }],
  unknown_gender: { customers: 5 },
  age_bands: [],
  unknown_age: { customers: 9 },
  coverage: { gender_known: rate(4, 9, 44.4), age_known: rate(0, 9, null) },
  evidence: { gender: LOW, age_band: LOW },
  top_age_band: null,
  busiest_weekday: { label: 'Saturday', per_occurrence: 4.0 },
  slowest_weekday: null,
  top_item: null
};

/* A branch with no code at all — the column is nullable until every row has been assigned one,
   and a firm mid-backfill must still read a name here rather than a bare separator. */
const BRANCH_THREE = {
  branch: { id: 'br-3', code: null, name: 'Jurong', is_default: false },
  visits: 12, revenue_cents: 34000, customers: 5, new_customers: 1,
  share_of_visits: rate(12, 50, 24.0),
  share_of_revenue: rate(34000, 164000, null),
  gender: [],
  unknown_gender: { customers: 5 },
  age_bands: [],
  unknown_age: { customers: 5 },
  coverage: { gender_known: rate(0, 5, null), age_known: rate(0, 5, null) },
  evidence: { gender: LOW, age_band: LOW },
  top_age_band: null,
  busiest_weekday: null,
  slowest_weekday: null,
  top_item: { item_name: 'trim', item_type: 'service', revenue_cents: 12000, buyers: 3 }
};

const COMPARISON = {
  scope: { business_id: 'b', branch_id: null, from: '2026-03-02', to: '2026-03-29' },
  business: { visits: 50, revenue_cents: 164000, customers: 26 },
  branches_compared: 3,
  branches_hidden: 2,
  limitation: 'Sales are attributed to the branch recorded on the sale.',
  evidence_class: 'DIRECT_FACT',
  branches: [BRANCH_ONE, BRANCH_TWO, BRANCH_THREE]
};

const FIRM_SCOPE = {
  branchId: null, branchCode: null, branchName: null,
  companySlug: 'kopi-lab', companyName: 'Kopi Lab'
};
const BRANCH_SCOPE = {
  branchId: 'br-1', branchCode: 'B01', branchName: 'Orchard',
  companySlug: 'kopi-lab', companyName: 'Kopi Lab'
};

const FULL = {
  currency: 'SGD', periodDays: 28, from: '2026-03-02', to: '2026-03-29',
  scope: FIRM_SCOPE, branches: COMPARISON, branchesError: ''
};

const L = 'ci-brief-branches-v778';

/* ==================================================================================================
   The scope line.
   ================================================================================================== */

test('V778 the brief says it is showing every branch, and names the company by its code', () => {
  const text = textOf(render(FULL));
  assert.ok(text.includes('Showing all branches · company code kopi-lab'),
    'the firm-wide line names the company code, not just "all branches"');
});

test('V778 a company with no code falls back to the name rather than printing an empty one', () => {
  const text = textOf(render({ ...FULL, scope: { ...FIRM_SCOPE, companySlug: null } }));
  assert.ok(text.includes('Showing all branches · company code Kopi Lab'));
  const bare = textOf(render({ ...FULL, scope: { ...FIRM_SCOPE, companySlug: null, companyName: null } }));
  assert.ok(bare.includes('Showing all branches'), 'a firm with neither still says what it is showing');
  assert.ok(!bare.includes('company code'), 'and never offers a code it does not have');
});

test('V778 a selected branch is named by its code and its name, and only it', () => {
  const text = textOf(render({ ...FULL, scope: BRANCH_SCOPE }));
  assert.ok(text.includes('Showing B01 · Orchard only'));
  assert.ok(!text.includes('Showing all branches'));
});

test('V778 a branch whose code the directory has not supplied still reads as itself', () => {
  const text = textOf(render({ ...FULL, scope: { ...BRANCH_SCOPE, branchCode: null } }));
  assert.ok(text.includes('Showing Orchard only'),
    'the picker label is the fallback, and no bare separator is printed');
  assert.ok(!text.includes('· Orchard'));
});

test('V778 a brief assembled with no scope at all prints no scope line', () => {
  const html = render({ ...FULL, scope: null });
  assert.ok(!textOf(html).includes('Showing'));
  assert.ok(!html.includes('ci-brief-scope-v778'));
});

/* ==================================================================================================
   Block L — the comparison.
   ================================================================================================== */

test('V778 block L names each branch by its code and states the firm total above the table', () => {
  const section = sectionOf(render(FULL), L);
  const text = textOf(section);
  assert.ok(text.includes('Your branches side by side'));
  assert.ok(text.includes('Across all branches: 50 valid visits · SGD 1640.00 · 26 customers.'));
  assert.deepEqual(rowsOf(section, 'Branch'), ['B01 · Orchard', 'B02 · Tampines', 'Jurong'],
    'a branch with no code reads as its plain name, never as a dangling separator');
});

test('V778 block L prints each branch against the firm, counts first', () => {
  const section = sectionOf(render(FULL), L);
  assert.deepEqual(rowsOf(section, 'Valid visits'), ['20 · 40% of all', '18 · 36% of all', '12 · 24% of all']);
  assert.deepEqual(rowsOf(section, 'Revenue'), ['SGD 740.00 · 45%', 'SGD 560.00 · 34%', 'SGD 340.00'],
    'a share the reader withheld is omitted, and the money is still stated');
  assert.deepEqual(rowsOf(section, 'Customers'), ['12', '9', '5']);
  assert.deepEqual(rowsOf(section, 'New customers'), ['4', '2', '1']);
});

test('V778 block L keeps a withheld share withheld, with the base it was measured against', () => {
  const section = sectionOf(render(FULL), L);
  assert.deepEqual(rowsOf(section, 'Women'), ['6 of 8 (75%)', '3 of 4 — too few to say', '—']);
  assert.deepEqual(rowsOf(section, 'Men'), ['2 of 8 — too few to say', '—', '—'],
    'a subgroup under the floor never rounds to a percent, and never to a zero');
});

test('V778 block L names the top age band as a range, or says nothing', () => {
  const section = sectionOf(render(FULL), L);
  assert.deepEqual(rowsOf(section, 'Top age band'), ['25–30', '—', '—']);
  assert.ok(!textOf(section).includes('25_30'), 'the stored key never reaches an owner');
});

test('V778 block L states the busiest and quietest day per occurrence, or an em dash', () => {
  const section = sectionOf(render(FULL), L);
  assert.deepEqual(rowsOf(section, 'Busiest day'), ['Monday · 5.0/day', 'Saturday · 4.0/day', '—']);
  assert.deepEqual(rowsOf(section, 'Slowest day'), ['Wednesday · 1.5/day', '—', '—']);
  assert.deepEqual(rowsOf(section, 'Top item'), ['facial · SGD 1530.00', '—', 'trim · SGD 120.00']);
});

test('V778 block L says how many branches the caller is not being shown', () => {
  const many = textOf(sectionOf(render(FULL), L));
  assert.ok(many.includes('2 branches are outside what your role can see.'));
  const one = textOf(sectionOf(render({
    ...FULL, branches: { ...COMPARISON, branches_hidden: 1 }
  }), L));
  assert.ok(one.includes('1 branch is outside what your role can see.'),
    'one hidden branch reads in the singular');
  const none = textOf(sectionOf(render({
    ...FULL, branches: { ...COMPARISON, branches_hidden: 0 }
  }), L));
  assert.ok(!none.includes('outside what your role can see'),
    'nothing hidden, nothing said');
});

test('V778 block L states what a branch comparison can and cannot mean', () => {
  const text = textOf(sectionOf(render(FULL), L));
  assert.ok(text.includes('Branches are compared on where the sale was rung up. A customer who visits two branches is counted at each.'));
});

test('V778 block L is placed directly after the period-at-a-glance block', () => {
  const html = render(FULL);
  const glance = html.indexOf('ci-brief-glance-v771');
  const branches = html.indexOf(L);
  assert.ok(glance > -1 && branches > glance, 'the comparison follows the glance');
  const line = app.slice(app.indexOf('    ${glanceV771}${branchesV778}'));
  assert.equal(line.slice(0, line.indexOf('\n')).trim(),
    '${glanceV771}${branchesV778}${whenV774}${bringBackV771}${cashGapV774}${unusedV771}${topCustomersV771}${servicesV771}${staffBlockV774}${rewardsBlockV774}${whoV774}${limitsV771}');
});

/* ==================================================================================================
   Absence and refusal.
   ================================================================================================== */

test('V778 a branch-scoped brief has no comparison block at all', () => {
  const html = render({ ...FULL, scope: BRANCH_SCOPE });
  assert.equal(sectionOf(html, L), '', 'the scope line already answered the question');
  assert.ok(html.includes('<section class="card ci-owner-brief-v771"'), 'the brief itself still renders');
});

test('V778 a firm with a single branch has nothing to compare, so nothing is shown', () => {
  const html = render({ ...FULL, branches: { ...COMPARISON, branches_compared: 1, branches: [BRANCH_ONE] } });
  assert.equal(sectionOf(html, L), '', 'a one-row table would read as a ranking of one');
  const none = render({ ...FULL, branches: { ...COMPARISON, branches_compared: 0, branches: [] } });
  assert.equal(sectionOf(none, L), '');
});

test('V778 a reader that returned nothing and raised nothing removes the block entirely', () => {
  const html = render({ ...FULL, branches: null, branchesError: '' });
  assert.equal(sectionOf(html, L), '', 'absent, not an empty shell');
  assert.ok(html.includes('<section class="card ci-owner-brief-v771"'));
});

test('V778 a reader that refused shows one quiet error row and blanks nothing else', () => {
  const html = render({ ...FULL, branches: null, branchesError: 'permission denied for function get_ci_branch_comparison_v1' });
  const section = sectionOf(html, L);
  assert.ok(section.includes('<div class="err" role="status">'));
  assert.ok(textOf(section).includes('Your branches side by side could not load.'));
  assert.equal((html.match(/<div class="err" role="status">/g) || []).length, 1);
  assert.ok(textOf(html).includes('Showing all branches · company code kopi-lab'),
    'the scope line survives a refused comparison');
});

test('V778 a refusal on a branch-scoped brief is still not rendered', () => {
  const html = render({ ...FULL, scope: BRANCH_SCOPE, branches: null, branchesError: 'nope' });
  assert.equal(sectionOf(html, L), '');
});

/* ==================================================================================================
   The standing vocabulary rules.
   ================================================================================================== */

test('V778 the scope line and the comparison never leak machine vocabulary', () => {
  const cases = [
    FULL,
    { ...FULL, scope: BRANCH_SCOPE },
    { ...FULL, branches: null, branchesError: 'x' },
    { ...FULL, branches: {} },
    { ...FULL, branches: { business: {}, branches: [{}, {}] } },
    {
      ...FULL,
      branches: {
        business: { visits: null, revenue_cents: null, customers: null },
        branches_hidden: null,
        branches: [
          { branch: {}, share_of_visits: {}, share_of_revenue: {}, gender: [{}], age_bands: [{}], coverage: {}, evidence: {}, busiest_weekday: {}, slowest_weekday: {}, top_item: {} },
          { branch: { code: '', name: '' }, gender: [{ gender: 'female', share: {} }] }
        ]
      }
    }
  ];
  for (const [index, fixture] of cases.entries()) {
    const html = render(fixture);
    assert.ok(!/whatsapp/i.test(html), `fixture ${index}: analytics must not display anything with WhatsApp`);
    const wholeText = textOf(html);
    for (const banned of ['NaN', 'undefined', 'null', 'bps', 'cents', 'identified', 'Infinity']) {
      assert.ok(!wholeText.includes(banned),
        `fixture ${index}: "${banned}" must never reach an owner (${wholeText.slice(0, 400)})`);
    }
    const ownText = textOf(sectionOf(html, L) + ' ' + (html.match(/<p class="muted small ci-brief-scope-v778"[^>]*>[^<]*/) || [''])[0]);
    for (const banned of ['NaN', 'undefined', 'null', 'bps', 'cents', 'identified',
      'DIRECT_FACT', 'ASSOCIATION', 'evidence', 'Infinity', '_']) {
      assert.ok(!ownText.includes(banned),
        `fixture ${index}: "${banned}" must never reach an owner (${ownText.slice(0, 400)})`);
    }
    assert.ok(!/reader|get_ci_/.test(textOf(sectionOf(html, L))), `fixture ${index}: block L speaks to an owner`);
  }
});

test('V778 the page never labels a column with the bare word Visits', () => {
  const section = sectionOf(render(FULL), L);
  assert.ok(section.includes('<th>Valid visits</th>'));
  assert.ok(!/<th>Visits<\/th>/.test(section));
});

test('V778 the brief still renders from an empty object with neither reader wired', () => {
  const html = render({});
  assert.ok(html.includes('<section class="card ci-owner-brief-v771" aria-labelledby="ciOwnerBriefTitleV771">'));
  assert.equal(sectionOf(html, L), '');
  assert.ok(!html.includes('ci-brief-scope-v778'));
  assert.ok(!/NaN|undefined|Infinity/.test(textOf(html)));
});

/* ==================================================================================================
   Composition and wiring — the parts that cannot be executed from here.
   ================================================================================================== */

test('V778 both branch readers are called from the page and captured independently', () => {
  const directory = app.indexOf("sb.rpc('get_ci_branch_directory_v1'");
  assert.ok(directory > -1, 'the directory is read for the scope line');
  const directoryCall = app.slice(directory, app.indexOf('})', directory));
  assert.ok(directoryCall.includes('p_business:S.biz.id'), 'the directory is scoped to the open business');
  assert.ok(!directoryCall.includes('p_branch'), 'the directory IS the branch roster and takes no branch');

  const comparison = app.indexOf("sb.rpc('get_ci_branch_comparison_v1'");
  assert.ok(comparison > -1, 'the comparison is read for block L');
  const comparisonCall = app.slice(comparison, app.indexOf('})', comparison));
  assert.ok(comparisonCall.includes('p_business:S.biz.id'));
  assert.ok(comparisonCall.includes('p_from:fromDate') && comparisonCall.includes('p_to:toDate'),
    'the comparison takes the report range');
  assert.ok(!comparisonCall.includes('p_branch'), 'the comparison IS the per-branch split and takes no branch');
  assert.ok(app.includes("selectedBranchId\n        ?Promise.resolve({data:null,error:null})\n        :sb.rpc('get_ci_branch_comparison_v1'"),
    'the comparison is skipped entirely while a branch is selected');

  for (const name of ['BranchDirectory', 'BranchComparison']) {
    assert.ok(app.includes(`last${name}BundleV778=`), `${name} has its own bundle`);
    assert.ok(app.includes(`last${name}ErrorV778=`), `${name} has its own error`);
  }
  assert.ok(app.includes('scope:ownerBriefScopeV778(),'), 'the closure hands the renderer its scope');
  assert.ok(app.includes('branches:lastBranchComparisonBundleV778,branchesError:lastBranchComparisonErrorV778,'),
    'and the comparison bundle with its own error');
});

test('V778 the scope object is built from the directory, falling back to the picker label', () => {
  const at = app.indexOf('function ownerBriefScopeV778(){');
  assert.ok(at > -1);
  const fn = app.slice(at, app.indexOf('\n  }', at));
  assert.ok(fn.includes('branchCode:row?.code||null'), 'the code comes from the directory row');
  assert.ok(fn.includes('profileBranchScopeLabelV158()'), 'the picker label is the fallback name');
  assert.ok(fn.includes('companySlug:S.biz?.slug'), 'the company code is the business slug');
});

test('V778 every branch read that asks for a name also asks for its code', () => {
  const calls = app.match(/from\('branches'\)\s*\n?\s*\.select\('[^']*'/g) || [];
  assert.ok(calls.length >= 16, `expected the branch reads to still be there, found ${calls.length}`);
  for (const call of calls) {
    const columns = call.slice(call.indexOf(".select('") + ".select('".length, call.length - 1).split(',');
    if (!columns.includes('name')) continue;
    assert.ok(columns.includes('code'),
      `a branch read that names a branch must also carry its code: ${call}`);
  }
  assert.ok(app.includes("sb.from('staff_branches').select('branches(id,name,code,active,billing_state)')"),
    "an employee's own branches carry their codes too");
});

test('V778 one helper decides how a branch reads in every picker', () => {
  assert.ok(app.includes('function branchOptionLabelV778(branch){'));
  assert.equal((app.match(/branchOptionLabelV778\(/g) || []).length, 3,
    'one definition and exactly two pickers — the top bar and the shared branch filter');
  const at = app.indexOf('function branchOptionLabelV778(branch){');
  const fn = app.slice(at, app.indexOf('\n}', at));
  assert.ok(fn.includes("return code?`${code} · ${name}`:name;"),
    'a branch with no code keeps its plain name so nothing breaks before the codes exist');
});

test('V778 the Branches page leads each card with the branch code', () => {
  assert.ok(app.includes("<div><b data-merchant-content>${b.code?esc(String(b.code))+' · ':''}${esc(b.name)}</b>"),
    'the code is a bold prefix on the name, and absent when there is none');
});

test('V778 both readers are declared in the writer registry', () => {
  const registry = JSON.parse(readFileSync(join(root, 'docs', 'design', 'ps0', 'writer-registry.json'), 'utf8'));
  const ids = new Set((registry.allowlist || []).map((entry) => entry.id));
  for (const rpc of ['get_ci_branch_directory_v1', 'get_ci_branch_comparison_v1']) {
    assert.ok(ids.has(`browser.rpc:app/app.js:${rpc}`), `${rpc} is declared read-only in the registry`);
  }
});
