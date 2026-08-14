/* W6 RISK C — THE PUBLISHED TIER LADDER IS A THREE-STATE ANSWER, AND IT FAILS CLOSED.
 *
 * Client-only, no migration, no dependency. It ships alone because it is the one destructive defect
 * in the W6 design set: `loyalty_tiers` was read as `r.error?null:(r.data||[])` and every consumer
 * then wrote `Array.isArray(x)?x:[]`, so "the read failed" and "this firm has no rungs" became the
 * same value. Those two demand OPPOSITE behaviour:
 *
 *   · prefillTiersW6I2() fires on state.tiers.length===0, pushes three fresh-uuid rungs
 *     (Silver/Gold/Diamond) and marks them dirty, and the Tiers step's own Next WRITES them into a
 *     draft that create_loyalty_config_draft has already filled with the firm's REAL rungs. Cubbly
 *     would go 9 rungs → 12, three colliding, and publish projects all twelve.
 *   · tierMovementRiskW6I2() requires publishedTiersW6I2().length>0, so an unreadable ladder made
 *     the D3 downgrade warning and its tick disappear for exactly the firms it could not see.
 *
 * AND THE READ WAS NOT MERELY FALLIBLE — IT WAS FAILING FOR EVERY TENANT ON EVERY LOAD. The V303
 * read asked public.loyalty_tiers for `active`, a column that table has never had: `active` lives
 * on loyalty_tier_versions, and publish_loyalty_config projects only the active versions
 * ("… where config_version_id=p_version and business_id=… and active"), so every published rung is
 * active by construction. PostgREST answers an unknown column with 42703. Verified against
 * production gadpooereceldfpfxsod on 2026-08-14, where Cubbly's ladder had grown 3 → 6 → 9 rungs
 * across three consecutive owner sessions, duplicating thresholds 0 and 20, because the Tiers step
 * kept opening empty in front of an owner who already had a ladder.
 *
 * So the fix is both halves, and this file pins both: the column list is the published table's own,
 * so the read succeeds; and the answer is an envelope, so the failure is honest when it does not.
 *
 * WHY BEHAVIOURAL. W6i2's adversarial pass proved what source pins cost: nineteen regexes were
 * green through five confirmed defects and an entirely inert switchboard, because a regex that
 * matches the line it was written against still matches when the line's surroundings make it
 * meaningless. Two of the pins this wave had to REPLACE were pinning the defect itself — one
 * required the `Array.isArray(liveTiers)?liveTiers:[]` collapse, the other required `active` in the
 * select. So the wizard is RUN here, against its real source, and the assertions are about what the
 * owner sees and which RPC arguments leave the browser.
 *
 * The harness is deliberately a copy of w6i2-programmes-home.test.mjs's E-series harness rather
 * than an extraction: that file is 900 lines of shipped pins and a parallel session is in this
 * worktree. The one addition is a `sb.from('loyalty_tiers')` stub that behaves like PostgREST —
 * it knows the published table's real column list and answers 42703 to anything else, so re-adding
 * a version-only column to the select turns THIS file red instead of production. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const section = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
};
const stripComments = source => source
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^\s*\/\/.*$/gm, '');
const wizardSrc = section('async function growSetupWizardV301(', 'function growPublishFieldRowsV170(');
const growSrc = section('async function growPage(', '/* ---------- Bring-back playbooks');
const escReal = value => String(value ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* THE PUBLISHED PROJECTION'S REAL COLUMNS, read from production information_schema on 2026-08-14:
   select column_name from information_schema.columns
     where table_schema='public' and table_name='loyalty_tiers';
   `active` is NOT among them and never has been — it belongs to loyalty_tier_versions, and
   publish_loyalty_config filters on it while inserting the eight columns below. */
const PUBLISHED_TIER_COLUMNS = ['id', 'business_id', 'name', 'threshold', 'points_multiplier',
  'perk_note', 'sort', 'effective_from', 'expires_at'];

const datasetKey = name => name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
function makeDom() {
  let markup = '';
  const byId = new Map(), byAttr = new Map();
  const attrsOf = tag => {
    const out = {};
    for (const m of tag.matchAll(/([a-zA-Z0-9_:-]+)(?:="([^"]*)")?/g)) if (m[1]) out[m[1]] = m[2] ?? '';
    return out;
  };
  const tags = () => [...markup.matchAll(/<([a-z0-9]+)\b([^>]*)>/gi)].map(m => attrsOf(m[2]));
  const makeEl = attrs => {
    const dataset = {};
    Object.keys(attrs).forEach(k => { if (k.startsWith('data-')) dataset[datasetKey(k.slice(5))] = attrs[k] });
    return { attrs, dataset, value: attrs.value ?? '', checked: 'checked' in attrs,
      disabled: 'disabled' in attrs, textContent: '', onclick: null, onchange: null,
      addEventListener() {}, setAttribute() {}, removeAttribute() {}, focus() {},
      querySelector: () => null, querySelectorAll: () => [] };
  };
  const host = {
    get innerHTML() { return markup },
    set innerHTML(value) { markup = value; byId.clear(); byAttr.clear() },
    querySelectorAll(selector) {
      const m = /^\[([a-z0-9-]+)(?:="([^"]*)")?\]$/.exec(selector);
      if (!m) return [];
      if (!byAttr.has(m[1])) byAttr.set(m[1], tags().filter(t => m[1] in t).map(makeEl));
      const all = byAttr.get(m[1]);
      return m[2] === undefined ? all : all.filter(el => el.attrs[m[1]] === m[2]);
    },
    querySelector(selector) { return host.querySelectorAll(selector)[0] || null }
  };
  const $ = id => {
    if (byId.has(id)) return byId.get(id);
    const tag = tags().find(t => t.id === id);
    if (!tag) return null;
    const el = makeEl(tag);
    byId.set(id, el);
    return el;
  };
  return { host, $, get markup() { return markup } };
}

const spineHelpersSrc = section('const PROGRAMME_SWITCHES_V314={', 'const PRODUCT_INTERACTION_EVENTS_V100=');
const wizardConstsSrc = section('const GROW_SETUP_SWITCHES_W6I2=[', 'async function growSetupComparisonV301(');
const wizardFactory = new Function('S', 'sb', 'esc', 'CUI', '$', 'toast', 'ownerErrorText',
  'localizeWorkspaceSubtreeV97', 'expiryModeRequiresDays', 'growSetupComparisonV301',
  'pendingGrowSetupModelV303', 'pendingGrowSetupRewardV303', `
  ${spineHelpersSrc}
  ${wizardConstsSrc}
  ${wizardSrc}
  return {growSetupWizardV301,readLoyaltyTiersW6I2,tiersEnvelopeW6I2,tiersReadW6I2,
    tiersUnknownW6I2,LOYALTY_TIER_COLUMNS_W6I2};`);

const SPINE_KINDS = ['points', 'tiers', 'stamps', 'referral'];
const spineRows = on => SPINE_KINDS.map(kind => ({ kind, active: on.includes(kind) }));
/* Cubbly's real published ladder as at 2026-08-14 — nine rungs, three of them already duplicated
   at thresholds 0 and 20 by the very defect this file closes. Nothing in it is invented. */
const CUBBLY_LADDER = [['Bronze', 0], ['Essential', 0], ['Essential', 0], ['Silver', 10],
  ['Gold', 20], ['Gold', 20], ['Gold', 25], ['Diamond', 30], ['Diamond', 100]]
  .map(([name, threshold], index) => ({ id: `cubbly-${index}`, name, threshold,
    points_multiplier: 1, perk_note: null, sort: index, effective_from: null, expires_at: null }));

/* A `sb` that answers loyalty_tiers the way PostgREST does: a select naming a column the table does
   not have is 42703 and NO rows, which is the production failure this whole file exists for. */
function makeSb({ tierRows = [], tierFailures = 0, rpcHandlers = {} } = {}) {
  const rpc = [], tierReads = [];
  let failuresLeft = tierFailures;
  const defaults = {
    create_loyalty_config_draft: async () => ({ data: { version_id: 'draft-1', snapshot_hash: 'h1' }, error: null }),
    save_loyalty_config_draft: async () => ({ data: { snapshot_hash: 'h2' }, error: null }),
    save_loyalty_tier_draft_v143: async () => ({ data: { snapshot_hash: 'h3' }, error: null }),
    preview_publish_impact: async () => ({ data: { rules: [], requires_confirmation: false }, error: null }),
    publish_loyalty_config: async () => ({ data: {}, error: null }),
    save_referral_program: async () => ({ data: {}, error: null }),
    get_loyalty_reward_draft: async () => ({ data: { program: null, rewards: [], tiers: [] }, error: null }),
    set_programmes_v314: async args => ({ data: { programmes: Object.entries(args.p_switches)
      .map(([kind, active]) => ({ kind, active })) }, error: null })
  };
  const answerTiers = columns => {
    tierReads.push(columns);
    const asked = String(columns).split(',').map(c => c.trim());
    const unknown = asked.filter(column => !PUBLISHED_TIER_COLUMNS.includes(column));
    if (unknown.length) return { data: null,
      error: { code: '42703', message: `column loyalty_tiers.${unknown[0]} does not exist` } };
    if (failuresLeft > 0) { failuresLeft -= 1; return { data: null, error: { code: 'PGRST002' } } }
    return { data: tierRows, error: null };
  };
  const sb = {
    rpc: async (name, args) => { rpc.push({ name, args });
      return (rpcHandlers[name] || defaults[name] || (async () => ({ data: {}, error: null })))(args) },
    from: table => ({
      select: columns => table === 'loyalty_tiers'
        ? { eq: () => ({ order: () => Promise.resolve(answerTiers(columns)) }) }
        : { eq: () => ({ limit: async () => ({ data: [], error: null }),
            order: () => Promise.resolve({ data: [], error: null }) }) }
    })
  };
  return { sb, rpc, tierReads };
}

function mountWizard({ spine = spineRows(['points', 'tiers']), industry = 'salon', snapshot = {},
  liveTiers = null, startStep = 1, tierRows = [], tierFailures = 0, rpcHandlers = {} } = {}) {
  const dom = makeDom();
  const { sb, rpc, tierReads } = makeSb({ tierRows, tierFailures, rpcHandlers });
  const S = { biz: { id: 'biz-1', currency: 'SGD', industry, points_mode: 'redeem' },
    programmes: spine, programmesBusinessId: spine ? 'biz-1' : null, myRole: 'owner' };
  const api = wizardFactory(S, sb, escReal, { icon: () => '' }, dom.$, () => {},
    error => String(error?.message || error || ''), () => {},
    mode => mode === 'fixed' || mode === 'inactivity',
    async () => ({ error: null, lines: [], unreadable: [], draftActive: null }), null, null);
  const full = { currentVersion: 'v1', loyalty: null, rewards: [{ id: 'r1', customer_name: 'Free coffee',
    cost_points: 100, active: true, estimated_cost_cents: 300 }], draft: null, draftDetail: null,
    referral: null, ...snapshot };
  return { dom, S, sb, rpc, api, tierReads,
    open: () => api.growSetupWizardV301({ host: dom.host, snapshot: full, isCurrent: () => true,
      startStep, liveTiers }),
    press: async id => { const el = dom.$(id); assert.ok(el, `no #${id} on screen`); await el.onclick() },
    toggle: async id => { const el = dom.$(id); assert.ok(el, `no #${id} on screen`);
      el.checked = true; await el.onchange() },
    title: () => /<h3 class="grow-setup-title-v301">([^<]*)</.exec(dom.markup)?.[1] || '',
    error: () => /<div class="err" role="alert">([^<]*)</.exec(dom.markup)?.[1] || '',
    rungs: () => [...dom.markup.matchAll(/data-grow-setup-tierrow-v304="([^"]*)"/g)].map(m => m[1]),
    tierWrites: () => rpc.filter(call => call.name === 'save_loyalty_tier_draft_v143')
      .map(call => call.args.p_tier),
    called: name => rpc.filter(call => call.name === name) };
}

/* ============ 1. THE READ ITSELF — three states, and a column list that exists ============ */

test('RISK C read: a successful read with rungs is `rows`, and the select asks only for columns public.loyalty_tiers has', async () => {
  /* The column-coupled half. The stub is PostgREST-faithful, so the ONLY way this passes is a
     select the published projection can actually answer — which is what the shipped read could not
     do from V303 (2026-08-13) until this fix. */
  const w = mountWizard({ tierRows: CUBBLY_LADDER });
  const answer = await w.api.readLoyaltyTiersW6I2('biz-1');
  assert.deepEqual(w.tierReads, [w.api.LOYALTY_TIER_COLUMNS_W6I2],
    'the read must go through the one shared column list');
  assert.equal(answer.state, 'rows', `the read must succeed against the real table (got ${JSON.stringify(answer)})`);
  assert.equal(answer.rows.length, 9);
  assert.ok(!String(w.api.LOYALTY_TIER_COLUMNS_W6I2).split(',').includes('active'),
    '`active` is a loyalty_tier_versions column; asking public.loyalty_tiers for it is 42703');
});

test('RISK C read: a failed read is `unknown`, never an empty ladder', async () => {
  const w = mountWizard({ tierRows: CUBBLY_LADDER, tierFailures: 1 });
  assert.deepEqual(await w.api.readLoyaltyTiersW6I2('biz-1'), { state: 'unknown', rows: [] });
});

test('RISK C read: a firm with no rungs is `empty`, which is a different answer from `unknown`', async () => {
  const w = mountWizard({ tierRows: [] });
  assert.deepEqual(await w.api.readLoyaltyTiersW6I2('biz-1'), { state: 'empty', rows: [] });
});

test('RISK C envelope: everything unrecognised is UNKNOWN, and only a real read can say otherwise', () => {
  const w = mountWizard();
  const { tiersEnvelopeW6I2 } = w.api;
  for (const value of [null, undefined, 0, '', 'rows', {}, { state: 'unknown' }, { rows: [1] }, { state: 'nope', rows: [1] }])
    assert.equal(tiersEnvelopeW6I2(value).state, 'unknown', `${JSON.stringify(value)} must fail closed`);
  // A bare array is only ever produced by a successful read, so its LENGTH decides.
  assert.deepEqual(tiersEnvelopeW6I2([]), { state: 'empty', rows: [] });
  assert.equal(tiersEnvelopeW6I2([{ id: 't1' }]).state, 'rows');
  // And a caller's claim about itself never beats its own rows.
  assert.equal(tiersEnvelopeW6I2({ state: 'rows', rows: [] }).state, 'empty');
  assert.equal(tiersEnvelopeW6I2({ state: 'empty', rows: [{ id: 't1' }] }).state, 'rows');
});

/* ============ 2. AN UNREADABLE LADDER NEVER GETS WRITTEN TO ============ */

test('RISK C: a failed read prefills ZERO rungs — the destructive case, on Cubbly-shaped data', async () => {
  /* The whole defect in one test. Tiers is on, the firm has nine published rungs, the read failed,
     and there is no open draft — which is the state of 100% of tenants immediately after any
     publish, because snapshot.draftDetail is only read when a draft already exists. Collapsed, the
     wizard pushed Silver/Gold/Diamond here and the next line wrote them. */
  const w = mountWizard({ liveTiers: { state: 'unknown', rows: [] }, startStep: 6 });
  await w.open();
  assert.equal(w.title(), 'Step 6 of 7 · Tiers');
  assert.deepEqual(w.rungs(), [], 'not one rung may be invented on top of a ladder nobody can see');
  assert.doesNotMatch(w.dom.markup, /Silver|Gold|Diamond/,
    'no ready-made ladder, no prefilled rows: all three of them write rungs');
  assert.equal(w.dom.markup.includes('data-grow-setup-tier-default-v303'), false,
    'the one-tap chip writes three rungs locally and Next commits them — it must not be offered');
  assert.equal(w.dom.markup.includes('growSetupTierNameV303'), false,
    'the add form writes a rung IMMEDIATELY through save_loyalty_tier_draft_v143');
});

test('RISK C: a failed read refuses Next in the owner’s words, and writes nothing', async () => {
  const w = mountWizard({ liveTiers: { state: 'unknown', rows: [] }, startStep: 6 });
  await w.open();
  await w.press('growSetupNextV301');
  assert.equal(w.error(), 'We could not read your current tiers. Reload before editing the ladder.');
  assert.deepEqual(w.tierWrites(), [], 'Next is the line that turned invented rungs into written ones');
  assert.deepEqual(w.called('create_loyalty_config_draft'), [],
    'a refused step must not even open a draft');
  assert.equal(w.title(), 'Step 6 of 7 · Tiers', 'a refused step does not advance');
});

test('RISK C: a failed read shows the honest state and a Try again that actually re-reads', async () => {
  const w = mountWizard({ liveTiers: { state: 'unknown', rows: [] }, startStep: 6,
    tierRows: CUBBLY_LADDER });
  await w.open();
  assert.match(w.dom.markup, /Your tiers could not be read/);
  assert.match(w.dom.markup, /data-grow-setup-tiersunknown-w6i2/);
  await w.press('growSetupTiersRetryW6I2');
  assert.equal(w.tierReads.length, 1, 'Try again re-runs the read');
  assert.equal(w.rungs().length, 9, 'and the firm’s real ladder is what appears — nine rungs, not three');
  assert.doesNotMatch(w.dom.markup, /Your tiers could not be read/);
  assert.deepEqual(w.tierWrites(), [], 'reading a ladder writes nothing');
});

test('RISK C: a Try again that fails again says so and still refuses to write', async () => {
  const w = mountWizard({ liveTiers: { state: 'unknown', rows: [] }, startStep: 6,
    tierRows: CUBBLY_LADDER, tierFailures: 1 });
  await w.open();
  await w.press('growSetupTiersRetryW6I2');
  assert.match(w.error(), /still could not be read/);
  assert.deepEqual(w.rungs(), []);
  await w.press('growSetupNextV301');
  assert.deepEqual(w.tierWrites(), []);
});

/* ============ 3. THE TWO STATES THAT MUST NOT REGRESS ============ */

test('RISK C: an EMPTY read on a genuinely new firm still prefills exactly three rungs (D7)', async () => {
  /* D7's ruling survives the fix intact — this is the whole reason `empty` and `unknown` had to be
     told apart rather than the prefill simply being deleted. */
  const w = mountWizard({ liveTiers: [], startStep: 6 });
  await w.open();
  assert.equal(w.rungs().length, 3, 'a firm with no ladder is handed one');
  assert.match(w.dom.markup, /Silver/);
  assert.match(w.dom.markup, /Gold/);
  assert.match(w.dom.markup, /Diamond/);
  await w.press('growSetupNextV301');
  assert.deepEqual(w.tierWrites().map(tier => [tier.name, tier.threshold]),
    [['Silver', 0], ['Gold', 200], ['Diamond', 500]],
    'and Next writes exactly those three, through save_loyalty_tier_draft_v143');
});

test('RISK C: a successful read WITH rungs never prefills and never rewrites (D7 no retroactive enforcement)', async () => {
  /* The envelope shape, which is what growPage actually hands the wizard. Reading it as
     `Array.isArray(liveTiers)?liveTiers:[]` — the shape shipped before this fix — makes an envelope
     with nine rungs read as zero, so this is also where that spelling dies. */
  const w = mountWizard({ liveTiers: { state: 'rows', rows: CUBBLY_LADDER }, startStep: 6 });
  await w.open();
  assert.equal(w.rungs().length, 9, 'a firm holding nine rungs keeps nine');
  await w.press('growSetupNextV301');
  assert.deepEqual(w.tierWrites(), [],
    'nothing was touched this session, so nothing is written — 9 rungs must never become 12');
  assert.equal(w.title(), 'Step 7 of 7 · Go live', 'a readable ladder advances normally');
});

test('RISK C: a bare array is still read as a successful answer', async () => {
  /* The compatibility half of the envelope: an array is only ever produced by a read that worked,
     so it stays a first-class input rather than becoming UNKNOWN and refusing the step. */
  const w = mountWizard({ liveTiers: CUBBLY_LADDER, startStep: 6 });
  await w.open();
  assert.equal(w.rungs().length, 9);
  assert.doesNotMatch(w.dom.markup, /Your tiers could not be read/);
});

test('RISK C: a raised threshold on an ENVELOPE ladder still gates publish (D3 survives the fix)', async () => {
  /* The fix must not silence the gate it exists to protect. Silver moves 10 → 50, which can only
     move members DOWN, so the block names it and the tick is required — read out of the envelope
     the production page hands over, not out of a bare array. */
  const raised = [{ tier_id: 'cubbly-3', name: 'Silver', threshold: 50, active: true }];
  const w = mountWizard({ liveTiers: { state: 'rows', rows: CUBBLY_LADDER }, startStep: 7,
    snapshot: { draftDetail: { program: null, rewards: [], tiers: raised } } });
  await w.open();
  assert.match(w.dom.markup, /data-grow-setup-tiermove-w6i2/, 'a raised rung must be named');
  assert.match(w.dom.markup, /<s>10<\/s> → <b>50<\/b>/);
  assert.equal(w.dom.$('growSetupNextV301').disabled, true);
  await w.press('growSetupNextV301');
  assert.deepEqual(w.called('publish_loyalty_config'), []);
});

/* ============ 4. AN UNREADABLE LADDER NEVER SUPPRESSES THE D3 WARNING ============ */

test('RISK C: an unreadable ladder is AT RISK — the movement block renders and Publish is gated', async () => {
  /* The fail-open half. tierMovementRiskW6I2 used to require publishedTiersW6I2().length>0, and a
     failed read produced zero rows, so the one case where a downgrade could not be ruled out was
     the one case that published with no warning and no tick. */
  const w = mountWizard({ liveTiers: { state: 'unknown', rows: [] }, startStep: 7 });
  await w.open();
  assert.match(w.dom.markup, /data-grow-setup-tiermove-w6i2/, 'the movement block must be on screen');
  assert.match(w.dom.markup, /The published ladder could not be read, so we cannot say who moves\./);
  assert.match(w.dom.markup, /id="growSetupTierAckW6I2"/, 'and the D3 tick must be required');
  assert.equal(w.dom.$('growSetupNextV301').disabled, true, 'Publish is disabled until it is ticked');
  await w.press('growSetupNextV301');
  assert.deepEqual(w.called('publish_loyalty_config'), [],
    'the gate is re-checked in the flow, not only rendered as a disabled attribute');
  assert.match(w.error(), /we cannot say who moves/);
});

test('RISK C: ticking the D3 box publishes — the gate is an admission, not a dead end', async () => {
  const w = mountWizard({ liveTiers: { state: 'unknown', rows: [] }, startStep: 7 });
  await w.open();
  await w.toggle('growSetupTierAckW6I2');
  await w.press('growSetupNextV301');
  assert.equal(w.called('publish_loyalty_config').length, 1);
});

test('RISK C: a readable ladder with no downgrade still publishes with no block at all', async () => {
  /* The other direction, so the fix cannot be "always warn", which is the same as never warning. */
  const w = mountWizard({ liveTiers: CUBBLY_LADDER, startStep: 7,
    snapshot: { draftDetail: { program: null, rewards: [], tiers: CUBBLY_LADDER.map(tier =>
      ({ tier_id: tier.id, name: tier.name, threshold: tier.threshold, active: true })) } } });
  await w.open();
  assert.doesNotMatch(w.dom.markup, /data-grow-setup-tiermove-w6i2/);
  assert.equal(w.dom.$('growSetupNextV301').disabled, false);
});

test('RISK C: tiers switched OFF is never at risk, however unreadable the ladder is', async () => {
  const w = mountWizard({ spine: spineRows(['points']), liveTiers: { state: 'unknown', rows: [] },
    startStep: 5 });
  await w.open();
  assert.equal(w.title(), 'Step 5 of 5 · Go live');
  assert.doesNotMatch(w.dom.markup, /data-grow-setup-tiermove-w6i2/,
    'nobody climbs a ladder that is switched off, so nobody can be moved down one');
  assert.equal(w.dom.$('growSetupNextV301').disabled, false);
});

/* ============ 5. THE COLLAPSE STAYS DELETED ============ */

test('RISK C: no consumer reads the ladder as a possibly-null array any more', () => {
  /* The one source-shaped test in this file, and it is the legitimate kind: a "the deleted shape
     stays deleted" pin. `loyaltyTiersV229.length` on an envelope is `undefined` — falsy, silent,
     and exactly the class of regression that ships without a crash. */
  const grow = stripComments(growSrc), wizard = stripComments(wizardSrc);
  assert.doesNotMatch(grow, /loyaltyTiersV229===null/);
  assert.doesNotMatch(grow, /loyaltyTiersV229\.length/);
  assert.doesNotMatch(grow, /loyaltyTiersV229&&/);
  assert.doesNotMatch(grow, /loyaltyTiersV229\.map\(/);
  assert.doesNotMatch(grow, /loyaltyTiersV229\.slice\(/);
  assert.doesNotMatch(wizard, /Array\.isArray\(liveTiers\)\?liveTiers/);
  // The grow page reads through the one shared helper, so it inherits the three states proven above.
  assert.match(grow, /const loyaltyTiersV229=canRewards\?await readLoyaltyTiersW6I2\(S\.biz\.id\):tiersReadW6I2\(\[\]\);/);
  // And the page says so when it cannot read, instead of printing "No tiers yet" over nine rungs.
  assert.match(grow, /data-grow-tiersunknown-w6i2/);
  assert.match(grow, /Your tiers could not be read/);
});
