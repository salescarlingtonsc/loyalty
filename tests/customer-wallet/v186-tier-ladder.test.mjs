import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const app = (await read('app/index.html')) + '\n' + (await read('app/app.js'));
const migration = await read('db/migrations/20260807_nestly_v186_customer_tier_ladder.sql');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

const ladder = section(app, 'function customerTierLadderMarkupV186', 'function customerTierRemainingTextV186');
const render = new Function(`${ladder}\n${section(app, 'function customerTierRemainingTextV186', '\nfunction customerMerchantExperienceMarkupV95')}
  ;const esc=value=>String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
  return customerTierLadderMarkupV186;`)();

const LADDER = {
  basis: 'points_earned',
  metric: 77276,
  tiers: [
    { id: 'a', label: 'Basic', threshold: 0, achieved: true, current: false, benefits: ['Earn 10 points for every SGD 1 spent'] },
    { id: 'b', label: 'Gold', threshold: 3000, achieved: true, current: false, benefits: ['Birthday treat every year', '5% off every visit'] },
    { id: 'c', label: 'Diamond', threshold: 10000, achieved: true, current: true, benefits: ['Birthday treat every year', '10% off every visit'] }
  ]
};

test('every tier is listed with its own benefits, not just the one the customer is on', () => {
  const html = render(LADDER);
  for (const rung of LADDER.tiers) {
    assert.ok(html.includes(`<b>${rung.label}</b>`), `${rung.label} must be listed`);
    for (const benefit of rung.benefits) {
      assert.ok(html.includes(benefit), `${rung.label}: "${benefit}" must stay readable`);
    }
  }
  assert.match(html, /All tiers/);
});

test('the current tier is the only one in colour, and says so in words', () => {
  const html = render(LADDER);
  assert.equal((html.match(/customer-tier-rung is-current/g) || []).length, 1);
  assert.match(html, /class="customer-tier-rung is-current" aria-current="true"/);
  assert.match(html, /<span class="pill ok">Your tier<\/span>/);
  assert.equal((html.match(/Your tier/g) || []).length, 1);
  assert.match(html, /<span class="pill off">Reached<\/span>/, 'a lower, already-passed tier reads as reached');
  const higher = render({ ...LADDER, metric: 500, tiers: LADDER.tiers.map((rung, index) => ({
    ...rung, achieved: index === 0, current: index === 0
  })) });
  assert.match(higher, /<span class="pill off">Not yet yours<\/span>/);
  assert.match(higher, /2,500 points to go/, 'an unreached tier states the exact gap');
});

test('masking is styling only — it never hides a benefit', () => {
  assert.match(app, /\.customer-tier-rung\{[^}]*filter:grayscale\(1\)/);
  assert.match(app, /\.customer-tier-rung\{[^}]*opacity:\.62/);
  assert.match(app, /\.customer-tier-rung\.is-current\{[^}]*filter:none;opacity:1/);
  assert.doesNotMatch(ladder, /display:none|hidden/, 'a tier that is not yours must still be fully visible');
  assert.match(app, /@media\(prefers-reduced-motion:reduce\)\{\.customer-tier-rung\{transition:none\}\}/);
});

test('the requirement line speaks the business’s own basis', () => {
  assert.match(render({ ...LADDER, basis: 'visits', tiers: [{ label: 'A', threshold: 0, benefits: [] }, { label: 'B', threshold: 5, benefits: [] }] }),
    /From 5 visits/);
  assert.match(render({ ...LADDER, basis: 'spend', tiers: [{ label: 'A', threshold: 0, benefits: [] }, { label: 'B', threshold: 3000, benefits: [] }] }),
    /From SGD 3,000 spent/);
  assert.match(render(LADDER), /From your first visit/, 'a zero threshold is not "From 0 points"');
  assert.match(render({ ...LADDER, tiers: [{ label: 'A', threshold: 0, benefits: [] }, { label: 'B', threshold: 10, benefits: [] }] }),
    /Benefits not published yet\./, 'a tier with no perks says so rather than rendering an empty list');
});

test('a single-tier programme renders no ladder at all', () => {
  assert.equal(render({ tiers: [LADDER.tiers[0]] }), '');
  assert.equal(render({ tiers: [] }), '');
  assert.equal(render({}), '');
  assert.equal(render({ tiers: [{ label: '  ', threshold: 0 }, { label: 'Gold', threshold: 10 }] }), '',
    'a blank label is not a tier');
});

test('the ladder hangs off the existing tier card', () => {
  assert.match(app, /\$\{customerTierLadderMarkupV186\(tier\)\}\s*<\/section>/);
});

/* ------------------------------------------------------------------------------ the server */

test('the ladder is server-derived and stays inside the effective window', () => {
  assert.match(migration, /create or replace function public\.customer_get_effective_tier_v143\(p_business uuid\)/);
  assert.match(migration, /'achieved',ladder\.threshold<=v_metric/);
  assert.match(migration, /'current',ladder\.id=v_current\.id/,
    'the client must never decide which tier the customer is on');
  assert.match(migration, /order by ladder\.threshold,ladder\.sort,ladder\.id/);
  assert.match(migration, /ladder\.effective_from is null or ladder\.effective_from<=statement_timestamp\(\)/);
  assert.match(migration, /ladder\.expires_at is null or ladder\.expires_at>statement_timestamp\(\)/);
  assert.match(migration, /ladder\.business_id=p_business/, 'tenant scope is not optional');
});

test('the contract is additive — every earlier field survives', () => {
  for (const key of ["'label'", "'current'", "'next'", "'progress_percent'", "'basis'", "'metric'"]) {
    assert.ok(migration.includes(key), `${key} must still be returned`);
  }
  assert.match(migration, /'tiers',v_tiers/);
  assert.match(migration, /set search_path = pg_catalog, public, app, pg_temp/);
  assert.match(migration, /revoke all on function public\.customer_get_effective_tier_v143\(uuid\) from public, anon/);
  assert.match(migration, /grant execute on function public\.customer_get_effective_tier_v143\(uuid\) to authenticated/);
  assert.match(migration, /verified customer link required/, 'the link check must not be lost in the rewrite');
  assert.match(migration, /authenticated customer session required/);
});
