// PS-0 canonical benefit-key templates — executable proof of the key grammar backing
// `benefit_fulfilments.UNIQUE(business_id, canonical_benefit_key)` (§3 of
// PROGRAM_STUDIO_ARCHITECTURE.md; the BENEFIT_REGISTRY_CONTRACT being written in
// parallel — §3's list is the authority here).
//
// REFERENCE IMPLEMENTATION only — a validated key GENERATOR + PARSER. No DB, no
// executor. The real PS-1B write-time validator must accept/reject exactly these forms.
//
// §3 registered templates (authority):
//   retention:{program}:{client}:{period_start}
//   tier_entry:{client}:{tier}
//   birthday:{client}:{year}
//   recurring:{rule}:{client}:{period_key}
//   campaign_offer:{campaign}:{client}
//   discount:{sale}:{rule}:{effect_index}          (per-event, N6)
//   sv_spend:{operation}:{movement}                (per-event, N6)

import assert from 'node:assert/strict';
import test from 'node:test';

// Each template is a family name + an ordered list of component field names. A key is
// `family:comp1:comp2:...`. Components must be non-empty and contain no ':' (the sole
// delimiter) — that keeps the mapping between a natural benefit and its key a bijection.
const TEMPLATES = {
  retention: ['program', 'client', 'period_start'],
  tier_entry: ['client', 'tier'],
  birthday: ['client', 'year'],
  recurring: ['rule', 'client', 'period_key'],
  campaign_offer: ['campaign', 'client'],
  discount: ['sale', 'rule', 'effect_index'],
  sv_spend: ['operation', 'movement'],
};

const COMPONENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/; // no colons, no spaces, non-empty

function buildBenefitKey(family, params) {
  const fields = TEMPLATES[family];
  if (!fields) throw new Error(`unknown benefit family: ${family}`);
  const parts = [family];
  for (const field of fields) {
    if (!(field in params)) throw new Error(`missing component '${field}' for family '${family}'`);
    const raw = String(params[field]);
    if (raw.length === 0) throw new Error(`empty component '${field}'`);
    if (raw.includes(':')) throw new Error(`component '${field}' must not contain the ':' delimiter`);
    if (!COMPONENT_RE.test(raw)) throw new Error(`component '${field}' is malformed: ${raw}`);
    parts.push(raw);
  }
  // reject any stray params the template doesn't declare (typo protection).
  for (const k of Object.keys(params)) {
    if (!fields.includes(k)) throw new Error(`unexpected component '${k}' for family '${family}'`);
  }
  return parts.join(':');
}

function parseBenefitKey(key) {
  if (typeof key !== 'string' || key.length === 0) throw new Error('empty key');
  const parts = key.split(':');
  const family = parts[0];
  const fields = TEMPLATES[family];
  if (!fields) throw new Error(`unknown benefit family: ${family}`);
  const comps = parts.slice(1);
  if (comps.length !== fields.length) {
    throw new Error(`family '${family}' expects ${fields.length} components, got ${comps.length}`);
  }
  const out = { family };
  fields.forEach((field, i) => {
    if (!COMPONENT_RE.test(comps[i])) throw new Error(`component '${field}' malformed: '${comps[i]}'`);
    out[field] = comps[i];
  });
  return out;
}

function isValidBenefitKey(key) {
  try { parseBenefitKey(key); return true; } catch { return false; }
}

// ---------------------------------------------------------------------------
// Well-formed keys per family.
// ---------------------------------------------------------------------------

test('generates well-formed keys for every §3 family', () => {
  assert.equal(buildBenefitKey('retention', { program: 'prog-1', client: 'c-9', period_start: '2026-07-01' }),
    'retention:prog-1:c-9:2026-07-01');
  assert.equal(buildBenefitKey('tier_entry', { client: 'c-9', tier: 'gold' }), 'tier_entry:c-9:gold');
  assert.equal(buildBenefitKey('birthday', { client: 'c-9', year: '2026' }), 'birthday:c-9:2026');
  assert.equal(buildBenefitKey('recurring', { rule: 'r-3', client: 'c-9', period_key: '2026-W32-day15' }),
    'recurring:r-3:c-9:2026-W32-day15');
  assert.equal(buildBenefitKey('campaign_offer', { campaign: 'camp-5', client: 'c-9' }),
    'campaign_offer:camp-5:c-9');
  assert.equal(buildBenefitKey('discount', { sale: 'sale-2', rule: 'r-1', effect_index: '0' }),
    'discount:sale-2:r-1:0');
  assert.equal(buildBenefitKey('sv_spend', { operation: 'op-4', movement: 'mv-77' }),
    'sv_spend:op-4:mv-77');
});

test('every generated key round-trips through the parser', () => {
  const key = buildBenefitKey('retention', { program: 'prog-1', client: 'c-9', period_start: '2026-07-01' });
  assert.deepEqual(parseBenefitKey(key), {
    family: 'retention', program: 'prog-1', client: 'c-9', period_start: '2026-07-01',
  });
});

// ---------------------------------------------------------------------------
// Collision behaviour: same natural benefit → same key; distinct → distinct.
// ---------------------------------------------------------------------------

test('the same natural benefit always produces the SAME key (idempotent identity)', () => {
  const a = buildBenefitKey('retention', { program: 'p', client: 'c', period_start: '2026-07' });
  const b = buildBenefitKey('retention', { program: 'p', client: 'c', period_start: '2026-07' });
  assert.equal(a, b); // this is what makes UNIQUE(...) a real double-grant guard
});

test('distinct benefits produce distinct keys — tricky pairs', () => {
  // two DIFFERENT campaigns, SAME client → must differ.
  const camp1 = buildBenefitKey('campaign_offer', { campaign: 'summer', client: 'c-9' });
  const camp2 = buildBenefitKey('campaign_offer', { campaign: 'winter', client: 'c-9' });
  assert.notEqual(camp1, camp2);

  // two DIFFERENT periods, SAME rule + client → must differ.
  const per1 = buildBenefitKey('recurring', { rule: 'r-3', client: 'c-9', period_key: '2026-08' });
  const per2 = buildBenefitKey('recurring', { rule: 'r-3', client: 'c-9', period_key: '2026-09' });
  assert.notEqual(per1, per2);

  // SAME campaign, two DIFFERENT clients → must differ.
  const cA = buildBenefitKey('campaign_offer', { campaign: 'summer', client: 'c-1' });
  const cB = buildBenefitKey('campaign_offer', { campaign: 'summer', client: 'c-2' });
  assert.notEqual(cA, cB);

  // tier entry: same client, different tiers → distinct.
  assert.notEqual(
    buildBenefitKey('tier_entry', { client: 'c-9', tier: 'silver' }),
    buildBenefitKey('tier_entry', { client: 'c-9', tier: 'gold' }),
  );

  // per-event: same sale + rule, different effect index → distinct.
  assert.notEqual(
    buildBenefitKey('discount', { sale: 's-1', rule: 'r-1', effect_index: '0' }),
    buildBenefitKey('discount', { sale: 's-1', rule: 'r-1', effect_index: '1' }),
  );
});

test('no cross-family collision — same component values, different families are distinct keys', () => {
  const birthday = buildBenefitKey('birthday', { client: 'c-9', year: '2026' });
  const tier = buildBenefitKey('tier_entry', { client: 'c-9', tier: '2026' });
  assert.notEqual(birthday, tier); // the family prefix disambiguates
});

test('generated keys are collision-free across a batch of distinct benefits', () => {
  const seen = new Set();
  for (let client = 0; client < 20; client++) {
    for (let period = 0; period < 12; period++) {
      const k = buildBenefitKey('recurring', {
        rule: 'r-3', client: `c-${client}`, period_key: `2026-${String(period + 1).padStart(2, '0')}`,
      });
      assert.ok(!seen.has(k), `unexpected collision at ${k}`);
      seen.add(k);
    }
  }
  assert.equal(seen.size, 20 * 12);
});

// ---------------------------------------------------------------------------
// Malformed-key rejection.
// ---------------------------------------------------------------------------

test('build rejects unknown families, missing components, and stray components', () => {
  assert.throws(() => buildBenefitKey('nope', { a: 1 }), /unknown benefit family/);
  assert.throws(() => buildBenefitKey('birthday', { client: 'c-9' }), /missing component 'year'/);
  assert.throws(() => buildBenefitKey('birthday', { client: 'c-9', year: '2026', extra: 'x' }),
    /unexpected component 'extra'/);
});

test('build rejects empty or delimiter-bearing components (bijection safety)', () => {
  assert.throws(() => buildBenefitKey('birthday', { client: '', year: '2026' }), /empty component/);
  assert.throws(() => buildBenefitKey('birthday', { client: 'c:9', year: '2026' }),
    /must not contain the ':' delimiter/);
  assert.throws(() => buildBenefitKey('tier_entry', { client: 'c 9', tier: 'gold' }), /malformed/);
});

test('parse rejects malformed keys: wrong arity, unknown family, bad components', () => {
  assert.equal(isValidBenefitKey('birthday:c-9:2026'), true);
  assert.equal(isValidBenefitKey('birthday:c-9'), false);            // too few
  assert.equal(isValidBenefitKey('birthday:c-9:2026:extra'), false); // too many
  assert.equal(isValidBenefitKey('mystery:c-9:2026'), false);        // unknown family
  assert.equal(isValidBenefitKey(''), false);
  assert.equal(isValidBenefitKey('retention::c:2026'), false);       // empty middle component
});

test('a parsed per-event key exposes its components for the executor', () => {
  assert.deepEqual(parseBenefitKey('sv_spend:op-4:mv-77'), { family: 'sv_spend', operation: 'op-4', movement: 'mv-77' });
  assert.deepEqual(parseBenefitKey('discount:sale-2:r-1:0'),
    { family: 'discount', sale: 'sale-2', rule: 'r-1', effect_index: '0' });
});
