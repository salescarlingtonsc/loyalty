// PS-0 canonical event identity — executable proof of §6 of
// PROGRAM_STUDIO_ARCHITECTURE.md (and the canonical-event-identity clause).
//
// REFERENCE IMPLEMENTATION only — no DB, no outbox, no executor. This models the
// producer-identity rules and the two uniqueness constraints the real PS-1B schema
// must enforce:
//   1. domain_events: UNIQUE(business_id, event_type, source_operation_id, schema_version)
//      — a random event_id references an event, it NEVER deduplicates one. The same
//      source fact re-emitted under fresh UUIDs inserts nothing new.
//   2. rule_effect_log: UNIQUE(event_id, rule_id, effect_index) — each effect of each
//      rule runs at most once per event, ever; a double-execution is swallowed.
//   3. A schema_version bump for an already-emitted source fact is NOT a dedup bypass:
//      it is rejected by the contract checker unless an explicit correction event exists.

import assert from 'node:assert/strict';
import test from 'node:test';

// Deterministic UUID minting — distinct but reproducible; NO Math.random / Date.now.
function uuidMinter(prefix = 'evt') {
  let n = 0;
  return () => {
    n += 1;
    const hex = n.toString(16).padStart(12, '0');
    return `${prefix}-00000000-0000-4000-8000-${hex}`;
  };
}

// ---------------------------------------------------------------------------
// Canonical producer identity (§6).
// ---------------------------------------------------------------------------
// `source_operation_id` is ALWAYS deterministic from the source fact:
//  - transactional producers → the source row/operation key (sale id, sv op id, redemption id)
//  - scheduled producers     → `sweep:{job}:{business}:{sgt_date}`
//  - period producers        → `period:{rule}:{client}:{period_key}`

function transactionalSourceKey(kind, sourceRowId) {
  if (!kind || !sourceRowId) throw new Error('transactional source key needs kind + source row id');
  return `${kind}:${sourceRowId}`;
}
function sweepSourceKey(job, business, sgtDate) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(sgtDate)) throw new Error('sweep source key needs an SGT yyyy-mm-dd date');
  return `sweep:${job}:${business}:${sgtDate}`;
}
function periodSourceKey(rule, client, periodKey) {
  if (!rule || !client || !periodKey) throw new Error('period source key needs rule + client + period');
  return `period:${rule}:${client}:${periodKey}`;
}

// ---------------------------------------------------------------------------
// Simulated emit-store with the UNIQUE constraint + effect log.
// ---------------------------------------------------------------------------

function createEmitStore() {
  const mintId = uuidMinter('evt');
  const events = new Map();       // eventKey -> stored event
  const byId = new Map();         // event_id -> stored event
  const effectLog = new Set();    // `${event_id}|${rule_id}|${effect_index}`
  const corrections = new Set();  // `${business}|${event_type}|${source_operation_id}` corrected forward

  const eventKey = (e) => `${e.business_id}|${e.event_type}|${e.source_operation_id}|${e.schema_version}`;
  const factKey = (e) => `${e.business_id}|${e.event_type}|${e.source_operation_id}`;

  // emit — models `INSERT ... ON CONFLICT (business,type,source_op,schema_version) DO NOTHING`.
  // Returns { inserted, event_id }. A fresh event_id is minted only on a real insert.
  function emit(evt) {
    if (evt.schema_version == null) throw new Error('schema_version is required');
    if (!evt.source_operation_id) throw new Error('source_operation_id is required (never a random uuid)');
    const k = eventKey(evt);
    if (events.has(k)) {
      return { inserted: false, event_id: events.get(k).event_id };
    }
    // schema-version guard: emitting a NEW schema_version for a source fact that already
    // has an emitted event, WITHOUT a registered correction, is rejected by the contract.
    const fk = factKey(evt);
    const priorVersions = [...events.values()].filter(
      (e) => factKey(e) === fk && e.schema_version !== evt.schema_version,
    );
    if (priorVersions.length > 0 && !corrections.has(fk)) {
      throw new Error(
        `schema_version bump for an already-emitted source fact requires an explicit correction event`,
      );
    }
    const event_id = evt.event_id ?? mintId();
    const stored = { ...evt, event_id };
    events.set(k, stored);
    byId.set(event_id, stored);
    return { inserted: true, event_id };
  }

  // registerCorrection — the ONLY sanctioned way to re-emit a source fact under a new
  // schema_version (models the correction-event rule of §6).
  function registerCorrection(business_id, event_type, source_operation_id) {
    corrections.add(`${business_id}|${event_type}|${source_operation_id}`);
  }

  // runEffect — models `INSERT ... ON CONFLICT (event_id, rule_id, effect_index) DO NOTHING`.
  // Returns true only the first time; a replay/double-execution returns false (swallowed).
  function runEffect(event_id, rule_id, effect_index) {
    if (!byId.has(event_id)) throw new Error('effect references an unknown event');
    const k = `${event_id}|${rule_id}|${effect_index}`;
    if (effectLog.has(k)) return false;
    effectLog.add(k);
    return true;
  }

  return {
    emit, registerCorrection, runEffect,
    get eventCount() { return events.size; },
    get effectCount() { return effectLog.size; },
  };
}

// ---------------------------------------------------------------------------
// Source-key determinism.
// ---------------------------------------------------------------------------

test('transactional source keys are deterministic from the source row', () => {
  assert.equal(transactionalSourceKey('sale', 'sale-42'), 'sale:sale-42');
  assert.equal(transactionalSourceKey('sv_op', 'op-9'), 'sv_op:op-9');
  // same fact → same key, always.
  assert.equal(transactionalSourceKey('sale', 'sale-42'), transactionalSourceKey('sale', 'sale-42'));
});

test('scheduled + period source keys are deterministic and reject malformed inputs', () => {
  assert.equal(sweepSourceKey('points_expiry', 'biz-1', '2026-07-23'), 'sweep:points_expiry:biz-1:2026-07-23');
  assert.equal(periodSourceKey('rule-7', 'client-3', '2026-W32-day15'), 'period:rule-7:client-3:2026-W32-day15');
  assert.throws(() => sweepSourceKey('job', 'biz', '23-07-2026'), /SGT yyyy-mm-dd/);
  assert.throws(() => periodSourceKey('rule', '', 'p'), /rule \+ client \+ period/);
});

// ---------------------------------------------------------------------------
// Replay proof: same source fact under fresh UUIDs inserts nothing new.
// ---------------------------------------------------------------------------

test('replaying a transactional source fact under fresh UUIDs inserts zero new rows', () => {
  const store = createEmitStore();
  const base = {
    business_id: 'biz-1', event_type: 'sale.completed', schema_version: 1,
    source_operation_id: transactionalSourceKey('sale', 'sale-42'),
  };
  const first = store.emit(base);
  assert.equal(first.inserted, true);
  assert.equal(store.eventCount, 1);
  // Re-invoke the producer three times, each supplying a DIFFERENT random event_id.
  for (const id of ['evt-x-1', 'evt-x-2', 'evt-x-3']) {
    const r = store.emit({ ...base, event_id: id });
    assert.equal(r.inserted, false);            // swallowed by the unique constraint
    assert.equal(r.event_id, first.event_id);   // returns the ORIGINAL event id
  }
  assert.equal(store.eventCount, 1);            // still exactly one event
});

test('re-running a scheduled sweep for the same SGT date produces the same identity and inserts nothing', () => {
  const store = createEmitStore();
  const evt = {
    business_id: 'biz-1', event_type: 'points.expiry_swept', schema_version: 1,
    source_operation_id: sweepSourceKey('points_expiry', 'biz-1', '2026-07-23'),
  };
  assert.equal(store.emit(evt).inserted, true);
  assert.equal(store.emit(evt).inserted, false); // idempotent sweep re-run
  assert.equal(store.emit({ ...evt, event_id: 'fresh' }).inserted, false);
  assert.equal(store.eventCount, 1);
  // a DIFFERENT date is a distinct fact → a new event.
  assert.equal(store.emit({ ...evt, source_operation_id: sweepSourceKey('points_expiry', 'biz-1', '2026-07-24') }).inserted, true);
  assert.equal(store.eventCount, 2);
});

test('period producers dedupe per (rule, client, period_key)', () => {
  const store = createEmitStore();
  const mk = (client, period) => ({
    business_id: 'biz-1', event_type: 'recurring.perk_period', schema_version: 1,
    source_operation_id: periodSourceKey('rule-7', client, period),
  });
  assert.equal(store.emit(mk('c1', '2026-08')).inserted, true);
  assert.equal(store.emit(mk('c1', '2026-08')).inserted, false); // same customer-period
  assert.equal(store.emit(mk('c2', '2026-08')).inserted, true);  // different client
  assert.equal(store.emit(mk('c1', '2026-09')).inserted, true);  // different period
  assert.equal(store.eventCount, 3);
});

// ---------------------------------------------------------------------------
// Schema-version bump requires a correction event.
// ---------------------------------------------------------------------------

test('a schema_version bump WITHOUT a correction event is rejected by the contract checker', () => {
  const store = createEmitStore();
  const base = {
    business_id: 'biz-1', event_type: 'sale.completed',
    source_operation_id: transactionalSourceKey('sale', 'sale-99'),
  };
  assert.equal(store.emit({ ...base, schema_version: 1 }).inserted, true);
  // bumping the schema for the SAME source fact is not a silent dedup bypass.
  assert.throws(
    () => store.emit({ ...base, schema_version: 2 }),
    /requires an explicit correction event/,
  );
  assert.equal(store.eventCount, 1);
});

test('a schema_version bump WITH a registered correction event is accepted', () => {
  const store = createEmitStore();
  const base = {
    business_id: 'biz-1', event_type: 'sale.completed',
    source_operation_id: transactionalSourceKey('sale', 'sale-99'),
  };
  store.emit({ ...base, schema_version: 1 });
  store.registerCorrection('biz-1', 'sale.completed', base.source_operation_id);
  const bumped = store.emit({ ...base, schema_version: 2 });
  assert.equal(bumped.inserted, true);
  assert.equal(store.eventCount, 2); // the correction supersedes, both rows retained as history
});

// ---------------------------------------------------------------------------
// Effect-level uniqueness: (event_id, rule_id, effect_index) swallows double execution.
// ---------------------------------------------------------------------------

test('effect-level uniqueness runs each (event, rule, effect_index) exactly once', () => {
  const store = createEmitStore();
  const { event_id } = store.emit({
    business_id: 'biz-1', event_type: 'sale.completed', schema_version: 1,
    source_operation_id: transactionalSourceKey('sale', 'sale-7'),
  });
  // rule R1 has two effects; rule R2 has one.
  assert.equal(store.runEffect(event_id, 'R1', 0), true);
  assert.equal(store.runEffect(event_id, 'R1', 1), true);
  assert.equal(store.runEffect(event_id, 'R2', 0), true);
  // every replay of any of them is swallowed.
  assert.equal(store.runEffect(event_id, 'R1', 0), false);
  assert.equal(store.runEffect(event_id, 'R1', 1), false);
  assert.equal(store.runEffect(event_id, 'R2', 0), false);
  assert.equal(store.effectCount, 3); // exactly three effects executed, ever
});

test('replaying the whole pipeline (event + effects) under fresh UUIDs changes nothing', () => {
  const store = createEmitStore();
  const evt = {
    business_id: 'biz-1', event_type: 'sale.completed', schema_version: 1,
    source_operation_id: transactionalSourceKey('sale', 'sale-500'),
  };
  const first = store.emit(evt);
  store.runEffect(first.event_id, 'grant-credit', 0);
  const eventsBefore = store.eventCount;
  const effectsBefore = store.effectCount;

  // Full replay: producer re-fires with a new uuid; effect-runner re-fires.
  const replay = store.emit({ ...evt, event_id: 'brand-new-uuid' });
  assert.equal(replay.inserted, false);
  assert.equal(replay.event_id, first.event_id);      // resolves to the original
  assert.equal(store.runEffect(replay.event_id, 'grant-credit', 0), false); // effect swallowed

  assert.equal(store.eventCount, eventsBefore);
  assert.equal(store.effectCount, effectsBefore);
});
