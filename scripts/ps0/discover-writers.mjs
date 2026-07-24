#!/usr/bin/env node
// PS-0 transaction-writer discovery tool (static analysis, read-only).
//
// Purpose: enumerate EVERY code path that can create or alter a customer-value
// row (sales, tenders, ledgers, fulfilments, inventory movement, ...) across the
// three surfaces of the Frenly platform:
//   1. supabase/migrations/*.sql   — SQL functions, triggers, migration backfills
//   2. supabase/functions/**/*.ts  — Edge Functions (service-role PostgREST/RPC)
//   3. app/index.html, app/customer-ui.js, app/join.html — browser call sites
//      (.from(...).insert/update/delete/upsert and .rpc('...'))
//
// Output: a DETERMINISTIC (sorted) JSON inventory to stdout. Re-running the tool
// on unchanged sources must produce byte-identical output; the exhaustiveness
// test (tests/program-studio/ps0-writer-registry.test.mjs) diffs this output
// against docs/design/ps0/writer-registry.json so any new writer that lands in
// code but is not curated into the registry fails CI.
//
// Fidelity notes (why this is more than a grep):
//   * Function bodies are located by dollar-quote matching that skips single-
//     quoted string literals, so a value-table name inside a text literal or a
//     commented-out statement is not mistaken for a write.
//   * "Latest definition wins": SQL objects are replayed in migration order.
//     CREATE OR REPLACE overwrites the keyed body; ALTER FUNCTION ... RENAME TO
//     re-keys it (this is how the reversal engine keeps v20/v34 base bodies
//     alive under *_v20_base / *_v34_base names). Overloads keyed by arity.
//   * A call graph over the resolved function set surfaces DELEGATING entry
//     points (record_sale_by_phone -> record_quick_sale, reverse_sale ->
//     reverse_sale_v34_base -> reverse_sale_v20_base, the v41/v51a idempotent
//     wrappers) that carry no direct DML yet reach a value writer.
//
// This tool NEVER connects to a database and NEVER executes SQL.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = join(__dirname, '..', '..');
const MIGRATIONS_DIR = join(REPO, 'supabase', 'migrations');
const FUNCTIONS_DIR = join(REPO, 'supabase', 'functions');
const BROWSER_FILES = ['app/index.html', 'app/customer-ui.js', 'app/join.html'];

// ---------------------------------------------------------------------------
// 1. The value-table registry: the declared authority for "what counts as
//    customer value". Every table here is something the Unified Checkout Kernel
//    must eventually own or reconcile. `value:true` = a write moves/promises
//    spendable value or hits P&L; `value:false` = op-ledger / audience /
//    provenance rows tracked so the report can reason about idempotency.
// ---------------------------------------------------------------------------
const VALUE_TABLES = {
  // --- money / sale spine ---
  sales:                          { category: 'sale',                value: true },
  sale_items:                     { category: 'sale_line',           value: true },
  payments:                       { category: 'payment',             value: true },
  credit_tenders:                 { category: 'credit_tender',       value: true },
  cash_drawer_movements:          { category: 'cash_drawer',         value: true },
  cash_drawer_sessions:           { category: 'cash_drawer',         value: true },
  // --- append-only ledgers ---
  credit_ledger:                  { category: 'credit_ledger',       value: true },
  points_ledger:                  { category: 'points_ledger',       value: true },
  points_batches:                 { category: 'points_batch',        value: true },
  // --- stored instruments ---
  gift_cards:                     { category: 'gift_card',           value: true },
  // --- packages ---
  client_packages:                { category: 'package',             value: true },
  package_session_consumptions:   { category: 'package_session',     value: true },
  package_session_reversals:      { category: 'package_reversal',    value: true },
  // --- memberships ---
  memberships:                    { category: 'membership',          value: true },
  // --- loyalty reward fulfilment / redemption ---
  reward_grants:                  { category: 'reward_grant',        value: true },
  loyalty_redemptions:            { category: 'redemption',          value: true },
  loyalty_redemption_reversals:   { category: 'redemption_reversal', value: true },
  loyalty_redemption_batch_drains:{ category: 'redemption',          value: true },
  loyalty_redemption_provenance:  { category: 'redemption_meta',     value: false },
  // --- birthday entitlements ---
  customer_birthday_entitlements: { category: 'birthday_entitlement', value: true },
  customer_birthday_redemptions:  { category: 'birthday_redemption',  value: true },
  // --- retention campaigns (v50) ---
  retention_campaign_grants:      { category: 'campaign_grant',      value: true },
  retention_campaign_returns:     { category: 'campaign_return',     value: true },
  retention_campaign_members:     { category: 'campaign_audience',   value: false },
  // --- inventory ---
  stock_batches:                  { category: 'inventory',           value: true },
  // --- P&L ---
  expenses:                       { category: 'expense_pl',          value: true },
  expense_recurrences:            { category: 'expense_pl',          value: true },
  // --- reversal provenance ---
  sale_reversal_audits:           { category: 'reversal',            value: true },
  sale_reversal_payment_links:    { category: 'reversal',            value: true },
  // --- idempotency / op ledgers (not value themselves, but a write here is the
  //     idempotency evidence, and the ABSENCE of one is a hard finding) ---
  financial_operations:                    { category: 'idempotency_ledger', value: false },
  loyalty_operations:                      { category: 'idempotency_ledger', value: false },
  sale_intent_operations:                  { category: 'idempotency_ledger', value: false },
  gift_card_issue_operations:              { category: 'idempotency_ledger', value: false },
  customer_birthday_activation_operations: { category: 'idempotency_ledger', value: false },
  f2_write_operations:                     { category: 'idempotency_ledger', value: false },
  // --- Program Studio PS-1B: entitlement PROMISES + fulfilment cost registry.
  //     These MOVE/PROMISE value (kernel must reconcile). The studio executor
  //     writes only promises here; NO ledger/tender/discount write exists yet.
  benefit_fulfilments:                     { category: 'benefit_fulfilment',  value: true },
  program_entitlements:                    { category: 'entitlement',         value: true },
  // --- PS-1B execution/idempotency/log surfaces (tracked, non-value): the event
  //     envelope, delivery outbox, capture provider, shadow log, effect log,
  //     budget counters, and op/marker ledgers.
  domain_events:                           { category: 'domain_event',        value: false },
  event_outbox:                            { category: 'outbox',              value: false },
  captured_messages:                       { category: 'captured_message',    value: false },
  benefit_shadow_evaluations:              { category: 'shadow_log',          value: false },
  rule_effect_log:                         { category: 'effect_log',          value: false },
  budget_periods:                          { category: 'budget',              value: false },
  budget_reservations:                     { category: 'budget',              value: false },
  program_entitlement_operations:          { category: 'idempotency_ledger',  value: false },
  domain_event_execution:                  { category: 'idempotency_ledger',  value: false },
  // --- Program Studio PS-1C: the unified checkout kernel. checkout_discount_lines
  //     is the per-effect applied-discount record (VALUE - it reduces the sale and
  //     is the kernel's authoritative discount provenance). The evaluation token +
  //     its op-ledger are priced quotes / idempotency (non-value); budget release is
  //     the reversal side of the v56 budget counters (non-value).
  checkout_evaluations:                    { category: 'checkout_evaluation', value: false },
  checkout_evaluation_operations:          { category: 'idempotency_ledger',  value: false },
  checkout_discount_lines:                 { category: 'checkout_discount',   value: true },
  budget_commitment_releases:              { category: 'budget',              value: false },
  // --- Program Studio PS-2A (v61) stored-value FOUNDATION. sv_lot_movements is the
  //     append-only ledger AUTHORITY and sv_lots the immutable minted parcels (VALUE - the
  //     mint moves stored value). sv_operations is the idempotency envelope and sv_accounts
  //     the balance-free container (non-value). No spend/refund path exists yet (Increment
  //     C+); balances are DERIVED (no mutable balance column anywhere).
  sv_lots:                                 { category: 'stored_value_lot',     value: true },
  sv_lot_movements:                        { category: 'stored_value_ledger',  value: true },
  sv_operations:                           { category: 'idempotency_ledger',   value: false },
  sv_accounts:                             { category: 'stored_value_account', value: false },
};

// Mutable-balance / alternate-naming stored-value tables that MUST NEVER exist. PS-2A
// (v61) legitimately introduces the lot-based FOUNDATION (sv_lots / sv_lot_movements /
// sv_plans / sv_plan_versions / sv_accounts / sv_operations / sv_authority) whose balances
// are DERIVED, so those are now curated VALUE_TABLES above rather than forbidden. This list
// keeps the anti-pattern tripwire: a single-balance stored_value table, an sv_balances cache,
// or a gift_card_lots shadow would falsify the "no mutable stored-value balance" claim.
const FORBIDDEN_STORED_VALUE_TABLES = [
  'stored_value', 'sv_balances',
  'stored_value_lots', 'stored_value_movements', 'gift_card_lots',
];

const VALUE_TABLE_NAMES = new Set(Object.keys(VALUE_TABLES));

// ---------------------------------------------------------------------------
// 2. Low-level SQL lexing helpers.
// ---------------------------------------------------------------------------
function stripSqlComments(s) {
  let out = '';
  let i = 0;
  const n = s.length;
  while (i < n) {
    const c = s[i];
    const c2 = s[i + 1];
    if (c === "'") {
      out += c; i++;
      while (i < n) {
        if (s[i] === "'" && s[i + 1] === "'") { out += "''"; i += 2; continue; }
        if (s[i] === "'") { out += "'"; i++; break; }
        out += s[i]; i++;
      }
      continue;
    }
    if (c === '-' && c2 === '-') { while (i < n && s[i] !== '\n') i++; continue; }
    if (c === '/' && c2 === '*') { i += 2; while (i < n && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
    out += c; i++;
  }
  return out;
}

// Strip comments AND blank single-quoted string literals, so a value-table name
// or a function name that appears only inside a RAISE message / text literal is
// never mistaken for a statement. (Verified: this corpus has no dynamic-SQL
// value writes — every EXECUTE format() is DDL/grants — so nothing real is lost.)
function codeOnly(text) {
  const s = stripSqlComments(text);
  let out = '';
  let i = 0;
  const n = s.length;
  while (i < n) {
    if (s[i] === "'") {
      out += "''"; i++;
      while (i < n) { if (s[i] === "'" && s[i + 1] === "'") { i += 2; continue; } if (s[i] === "'") { i++; break; } i++; }
      continue;
    }
    out += s[i]; i++;
  }
  return out;
}

function findDollarClose(raw, openStart, tag) {
  let i = openStart + tag.length;
  const n = raw.length;
  while (i < n) {
    if (raw[i] === "'") {
      i++;
      while (i < n) { if (raw[i] === "'" && raw[i + 1] === "'") { i += 2; continue; } if (raw[i] === "'") { i++; break; } i++; }
      continue;
    }
    if (raw.startsWith(tag, i)) return i + tag.length;
    i++;
  }
  return -1;
}

const DOLLAR_TAG = /\$[a-zA-Z0-9_]*\$/y;
function readDollarTagAt(raw, pos) {
  DOLLAR_TAG.lastIndex = pos;
  const m = DOLLAR_TAG.exec(raw);
  return m && m.index === pos ? m[0] : null;
}

// Count top-level parameters starting at the '(' after a function name.
function parseArity(raw, openParenIdx) {
  let i = openParenIdx + 1;
  const n = raw.length;
  let depth = 1, sawAny = false, commas = 0;
  while (i < n && depth > 0) {
    const c = raw[i];
    if (c === "'") { i++; while (i < n) { if (raw[i] === "'" && raw[i + 1] === "'") { i += 2; continue; } if (raw[i] === "'") { i++; break; } i++; } continue; }
    if (c === '$') { const tag = readDollarTagAt(raw, i); if (tag) { const close = findDollarClose(raw, i, tag); i = close < 0 ? n : close; continue; } }
    if (c === '(') { depth++; i++; continue; }
    if (c === ')') { depth--; i++; continue; }
    if (!/\s/.test(c)) sawAny = true;
    if (c === ',' && depth === 1) commas++;
    i++;
  }
  return sawAny ? commas + 1 : 0;
}

// Count comma-separated argument types inside a (type,type,...) list string.
function arityFromArgList(argList) {
  const inner = argList.trim().replace(/^\(/, '').replace(/\)$/, '').trim();
  if (!inner) return 0;
  let depth = 0, commas = 0;
  for (const ch of inner) {
    if (ch === '(' || ch === '[') depth++;
    else if (ch === ')' || ch === ']') depth--;
    else if (ch === ',' && depth === 0) commas++;
  }
  return commas + 1;
}

// ---------------------------------------------------------------------------
// 3. Per-file event extraction: CREATE FUNCTION defs and ALTER ... RENAME TO,
//    both tagged with their source index so we can replay them in order.
// ---------------------------------------------------------------------------
const FN_HEADER_SCAN = /create\s+(?:or\s+replace\s+)?function\s+([a-z0-9_]+)\.([a-z0-9_]+)\s*\(/gi;
const RENAME_SCAN = /alter\s+function\s+([a-z0-9_]+)\.([a-z0-9_]+)\s*(\([^;]*?\))\s*rename\s+to\s+([a-z0-9_]+)/gi;
const SETSCHEMA_SCAN = /alter\s+function\s+([a-z0-9_]+)\.([a-z0-9_]+)\s*(\([^;]*?\))\s*set\s+schema\s+([a-z0-9_]+)/gi;
const DROPFN_SCAN = /drop\s+function\s+(?:if\s+exists\s+)?([a-z0-9_]+)\.([a-z0-9_]+)\s*(\([^;]*?\))/gi;

function extractFileEvents(raw) {
  const events = [];
  const cleaned = raw; // dollar/string aware routines handle literals themselves

  let m;
  FN_HEADER_SCAN.lastIndex = 0;
  while ((m = FN_HEADER_SCAN.exec(cleaned)) !== null) {
    const schema = m[1].toLowerCase();
    const name = m[2].toLowerCase();
    const openParen = m.index + m[0].length - 1;
    const arity = parseArity(cleaned, openParen);
    // locate body (first dollar span after the signature)
    let i = m.index + m[0].length;
    let bodyInner = '';
    while (i < cleaned.length) {
      if (cleaned[i] === "'") { i++; while (i < cleaned.length) { if (cleaned[i] === "'" && cleaned[i + 1] === "'") { i += 2; continue; } if (cleaned[i] === "'") { i++; break; } i++; } continue; }
      if (cleaned[i] === '$') { const tag = readDollarTagAt(cleaned, i); if (tag) { const close = findDollarClose(cleaned, i, tag); if (close < 0) break; bodyInner = cleaned.slice(i + tag.length, close - tag.length); break; } }
      if (cleaned[i] === ';') break;
      i++;
    }
    events.push({ kind: 'create', index: m.index, schema, name, arity, bodyInner });
  }

  RENAME_SCAN.lastIndex = 0;
  while ((m = RENAME_SCAN.exec(cleaned)) !== null) {
    events.push({
      kind: 'rename', index: m.index,
      schema: m[1].toLowerCase(), name: m[2].toLowerCase(),
      arity: arityFromArgList(m[3]), newName: m[4].toLowerCase(),
    });
  }

  SETSCHEMA_SCAN.lastIndex = 0;
  while ((m = SETSCHEMA_SCAN.exec(cleaned)) !== null) {
    events.push({
      kind: 'setschema', index: m.index,
      schema: m[1].toLowerCase(), name: m[2].toLowerCase(),
      arity: arityFromArgList(m[3]), newSchema: m[4].toLowerCase(),
    });
  }

  DROPFN_SCAN.lastIndex = 0;
  while ((m = DROPFN_SCAN.exec(cleaned)) !== null) {
    events.push({
      kind: 'drop', index: m.index,
      schema: m[1].toLowerCase(), name: m[2].toLowerCase(),
      arity: arityFromArgList(m[3]),
    });
  }

  return events.sort((a, b) => a.index - b.index);
}

// ---------------------------------------------------------------------------
// 4. Value-table DML + call detection inside a function body.
// ---------------------------------------------------------------------------
const DML_RE = /\b(insert\s+into|update|delete\s+from)\s+(?:only\s+)?(?:(?:public|app)\.)?("?)([a-z0-9_]+)\2/gi;

function findValueWrites(text) {
  const writes = new Map();
  const cleaned = codeOnly(text);
  let m;
  DML_RE.lastIndex = 0;
  while ((m = DML_RE.exec(cleaned)) !== null) {
    const table = m[3].toLowerCase();
    if (!VALUE_TABLE_NAMES.has(table)) continue;
    const verb = m[1].toLowerCase();
    const op = verb.startsWith('insert') ? 'INSERT' : verb.startsWith('update') ? 'UPDATE' : 'DELETE';
    if (!writes.has(table)) writes.set(table, new Set());
    writes.get(table).add(op);
  }
  return writes;
}

function writesToArray(writesMap) {
  return [...writesMap.entries()]
    .map(([table, ops]) => ({ table, category: VALUE_TABLES[table].category, value: VALUE_TABLES[table].value, ops: [...ops].sort() }))
    .sort((a, b) => a.table.localeCompare(b.table));
}

// Detect calls to schema-qualified functions in a body: public.foo( / app.bar(
function findCalls(text, knownNames) {
  const cleaned = codeOnly(text);
  const calls = new Set();
  for (const m of cleaned.matchAll(/\b(public|app)\.([a-z0-9_]+)\s*\(/gi)) {
    const key = `${m[1].toLowerCase()}.${m[2].toLowerCase()}`;
    if (knownNames.has(key)) calls.add(key);
  }
  return calls;
}

// Behavioural flags for the registry, detected heuristically from a body.
function bodyFlags(text) {
  const c = codeOnly(text).toLowerCase();
  return {
    idempotency: /financial_operations|loyalty_operations|sale_intent_operations|gift_card_issue_operations|customer_birthday_activation_operations|on conflict|idem_key|idempotency/.test(c),
    advisory_lock: /pg_advisory_xact_lock|pg_advisory_lock/.test(c),
    row_lock_for_update: /for\s+update/.test(c),
    config_version_ref: /config_version|stamp_config_version|firm_config_versions|loyalty_config/.test(c),
    sale_policy_ref: /sale_policy|sale_policies|counts_as_revenue|counts_as_visit|earns_points/.test(c),
  };
}

// ---------------------------------------------------------------------------
// 5. Trigger extraction.
// ---------------------------------------------------------------------------
const TRIGGER_RE = /create\s+(?:or\s+replace\s+)?(?:constraint\s+)?trigger\s+([a-z0-9_]+)\s+(before|after|instead\s+of)\s+([a-z0-9_\s,]+?)\s+on\s+(?:(?:public|app)\.)?([a-z0-9_]+)\b[\s\S]*?execute\s+(?:function|procedure)\s+(?:([a-z0-9_]+)\.)?([a-z0-9_]+)\s*\(/gi;

function extractTriggers(text) {
  const cleaned = stripSqlComments(text);
  const out = [];
  let m;
  TRIGGER_RE.lastIndex = 0;
  while ((m = TRIGGER_RE.exec(cleaned)) !== null) {
    out.push({
      trigger: m[1].toLowerCase(),
      timing: m[2].toLowerCase().replace(/\s+/g, ' '),
      events: m[3].toLowerCase().replace(/\s+/g, ' ').split(/\s+or\s+/).map((s) => s.trim()).filter(Boolean).sort(),
      table: m[4].toLowerCase(),
      fn_schema: (m[5] || 'public').toLowerCase(),
      fn_name: m[6].toLowerCase(),
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// 6. Scan the migration corpus, replaying create/rename in order.
// ---------------------------------------------------------------------------
function scanMigrations() {
  const files = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort();
  const defs = new Map();        // <schema>.<name>/<arity> -> { schema,name,arity,file,bodyInner }
  const triggerMap = new Map();  // <table>:<trigger> -> record
  const backfills = [];
  const forbiddenFound = [];

  for (const file of files) {
    const raw = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');

    for (const t of FORBIDDEN_STORED_VALUE_TABLES) {
      const re = new RegExp('create\\s+table\\s+(?:if\\s+not\\s+exists\\s+)?(?:(?:public|app)\\.)?' + t + '\\b', 'i');
      if (re.test(stripSqlComments(raw))) forbiddenFound.push({ table: t, file });
    }

    // Replay create/rename events in positional order.
    const events = extractFileEvents(raw);
    const bodyRanges = [];
    for (const ev of events) {
      if (ev.kind === 'create') {
        const key = `${ev.schema}.${ev.name}/${ev.arity}`;
        defs.set(key, { schema: ev.schema, name: ev.name, arity: ev.arity, file, bodyInner: ev.bodyInner });
      } else if (ev.kind === 'rename') {
        const oldKey = `${ev.schema}.${ev.name}/${ev.arity}`;
        const newKey = `${ev.schema}.${ev.newName}/${ev.arity}`;
        const moved = defs.get(oldKey);
        if (moved) {
          defs.set(newKey, { ...moved, name: ev.newName });
          defs.delete(oldKey);
        }
      } else if (ev.kind === 'setschema') {
        const oldKey = `${ev.schema}.${ev.name}/${ev.arity}`;
        const newKey = `${ev.newSchema}.${ev.name}/${ev.arity}`;
        const moved = defs.get(oldKey);
        if (moved) {
          defs.set(newKey, { ...moved, schema: ev.newSchema });
          defs.delete(oldKey);
        }
      } else if (ev.kind === 'drop') {
        defs.delete(`${ev.schema}.${ev.name}/${ev.arity}`);
      }
    }

    // triggers (latest file wins per table:trigger)
    for (const tr of extractTriggers(raw)) triggerMap.set(`${tr.table}:${tr.trigger}`, { ...tr, file });

    // migration-time backfills: DML OUTSIDE any function body.
    for (const m of raw.matchAll(FN_HEADER_SCAN)) { /* prime */ break; }
    FN_HEADER_SCAN.lastIndex = 0;
    let mm;
    while ((mm = FN_HEADER_SCAN.exec(raw)) !== null) {
      let i = mm.index + mm[0].length;
      while (i < raw.length) {
        if (raw[i] === "'") { i++; while (i < raw.length) { if (raw[i] === "'" && raw[i + 1] === "'") { i += 2; continue; } if (raw[i] === "'") { i++; break; } i++; } continue; }
        if (raw[i] === '$') { const tag = readDollarTagAt(raw, i); if (tag) { const close = findDollarClose(raw, i, tag); if (close < 0) break; bodyRanges.push([i, close]); break; } }
        if (raw[i] === ';') break;
        i++;
      }
    }
    let outside = '';
    let cursor = 0;
    for (const [s, e] of bodyRanges.sort((a, b) => a[0] - b[0])) { outside += raw.slice(cursor, s); cursor = e; }
    outside += raw.slice(cursor);
    const bfWrites = findValueWrites(outside);
    for (const w of writesToArray(bfWrites)) backfills.push({ id: `db.backfill:${file}:${w.table}`, file, ...w });
  }

  // Resolve writes/calls/flags per current def.
  const knownNames = new Set([...defs.values()].map((d) => `${d.schema}.${d.name}`));
  const fnMeta = new Map(); // schema.name -> aggregate across arities
  const perDef = [];
  for (const [key, d] of defs) {
    const writes = findValueWrites(d.bodyInner);
    const calls = findCalls(d.bodyInner, knownNames);
    const flags = bodyFlags(d.bodyInner);
    const rec = {
      id: `db.fn:${key}`, schema: d.schema, name: d.name, arity: d.arity,
      latest_file: d.file, writes: writesToArray(writes),
      calls: [...calls].sort(), flags,
      direct_value: [...writes.keys()].some((t) => VALUE_TABLES[t].value),
      direct_any: writes.size > 0,
    };
    perDef.push(rec);
    const nm = `${d.schema}.${d.name}`;
    if (!fnMeta.has(nm)) fnMeta.set(nm, { direct_value: false, direct_any: false, calls: new Set() });
    const agg = fnMeta.get(nm);
    if (rec.direct_value) agg.direct_value = true;
    if (rec.direct_any) agg.direct_any = true;
    for (const c of calls) agg.calls.add(c);
  }

  // Transitive reachability: does this function reach a direct value writer via calls?
  const reachesValue = new Map();
  function reaches(nm, seen = new Set()) {
    if (reachesValue.has(nm)) return reachesValue.get(nm);
    if (seen.has(nm)) return false;
    seen.add(nm);
    const meta = fnMeta.get(nm);
    if (!meta) return false;
    let r = meta.direct_value;
    if (!r) for (const c of meta.calls) if (reaches(c, seen)) { r = true; break; }
    reachesValue.set(nm, r);
    return r;
  }
  for (const nm of fnMeta.keys()) reaches(nm);

  // trigger fn classification
  const triggerFnKeys = new Set([...triggerMap.values()].map((tr) => `${tr.fn_schema}.${tr.fn_name}`));

  const dbWriters = perDef
    .filter((r) => r.direct_any) // has direct DML to a value/op table
    .map((r) => ({
      ...r,
      kind: triggerFnKeys.has(`${r.schema}.${r.name}`) ? 'db_trigger_function' : 'db_function',
      value_impact: r.direct_value,
    }))
    .sort((a, b) => a.id.localeCompare(b.id));

  // Delegating entry points: no direct DML of their own, but they invoke a
  // resolved callee that reaches a value writer. We require a NON-EMPTY resolved
  // target so a shadowed overload (name-level reachability with no real call)
  // never masquerades as a writer.
  const dbDelegators = perDef
    .map((r) => ({ r, targets: r.calls.filter((c) => reachesValue.get(c)) }))
    .filter(({ r, targets }) => !r.direct_any && targets.length > 0)
    .map(({ r, targets }) => ({
      ...r,
      kind: triggerFnKeys.has(`${r.schema}.${r.name}`) ? 'db_trigger_delegator' : 'db_delegating_entrypoint',
      value_impact: true,
      delegates_to: targets.sort(),
    }))
    .sort((a, b) => a.id.localeCompare(b.id));

  const valueWritingFnNames = new Set(dbWriters.filter((w) => w.value_impact).map((w) => `${w.schema}.${w.name}`));
  const anyWritingFnNames = new Set(dbWriters.map((w) => `${w.schema}.${w.name}`));
  const reachesValueNames = new Set([...fnMeta.keys()].filter((nm) => reachesValue.get(nm)));

  const triggers = [...triggerMap.values()]
    .map((tr) => {
      const fnKey = `${tr.fn_schema}.${tr.fn_name}`;
      return {
        id: `db.trigger:${tr.table}:${tr.trigger}`, trigger: tr.trigger, table: tr.table,
        timing: tr.timing, events: tr.events, function: fnKey, file: tr.file,
        writes_value: reachesValueNames.has(fnKey), writes_any: anyWritingFnNames.has(fnKey) || reachesValueNames.has(fnKey),
      };
    })
    .sort((a, b) => a.id.localeCompare(b.id));

  return {
    dbWriters, dbDelegators, triggers,
    backfills: backfills.sort((a, b) => a.id.localeCompare(b.id)),
    forbiddenFound, reachesValueNames, valueWritingFnNames,
  };
}

// ---------------------------------------------------------------------------
// 7. Edge functions.
// ---------------------------------------------------------------------------
function scanEdgeFunctions() {
  const out = [];
  if (!existsSync(FUNCTIONS_DIR)) return out;
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = join(dir, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (entry.name.endsWith('.ts')) {
        const raw = readFileSync(p, 'utf8');
        const rel = relative(REPO, p);
        const rpcs = [...raw.matchAll(/\.rpc\(\s*['"]([a-z0-9_]+)['"]/gi)].map((x) => x[1].toLowerCase());
        const writes = [...raw.matchAll(/\.from\(\s*['"]([a-z0-9_]+)['"]\s*\)\s*\.(insert|update|delete|upsert)\b/gi)].map((x) => ({ table: x[1].toLowerCase(), op: x[2].toUpperCase() }));
        if (rpcs.length || writes.length) {
          out.push({
            file: rel,
            rpcs_called: [...new Set(rpcs)].sort(),
            direct_writes: writes.filter((w) => VALUE_TABLE_NAMES.has(w.table))
              .map((w) => ({ id: `edge.write:${rel}:${w.table}:${w.op}`, ...w, category: VALUE_TABLES[w.table]?.category }))
              .sort((a, b) => a.id.localeCompare(b.id)),
          });
        }
      }
    }
  };
  walk(FUNCTIONS_DIR);
  return out.sort((a, b) => a.file.localeCompare(b.file));
}

// ---------------------------------------------------------------------------
// 8. Browser call sites.
// ---------------------------------------------------------------------------
function scanBrowser(reachesValueNames) {
  const valueRpcSet = new Set([...reachesValueNames].map((f) => f.split('.').pop()));
  const directWrites = [];
  const rpcCalls = [];
  for (const rel of BROWSER_FILES) {
    const abs = join(REPO, rel);
    if (!existsSync(abs)) continue;
    const raw = readFileSync(abs, 'utf8');
    for (const x of raw.matchAll(/\.from\(\s*['"]([a-z0-9_]+)['"]\s*\)\s*\.(insert|update|delete|upsert)\b/gi)) {
      const table = x[1].toLowerCase();
      const op = x[2].toUpperCase();
      const isValue = VALUE_TABLE_NAMES.has(table);
      directWrites.push({ id: `browser.write:${rel}:${table}:${op}`, file: rel, table, op, value_table: isValue, category: isValue ? VALUE_TABLES[table].category : 'non_value', value_impact: isValue && VALUE_TABLES[table].value });
    }
    for (const x of raw.matchAll(/\.rpc\(\s*['"]([a-z0-9_]+)['"]/gi)) {
      const rpc = x[1].toLowerCase();
      rpcCalls.push({ id: `browser.rpc:${rel}:${rpc}`, file: rel, rpc, reaches_value_writer: valueRpcSet.has(rpc) });
    }
  }
  const dedupe = (arr) => { const seen = new Map(); for (const r of arr) if (!seen.has(r.id)) seen.set(r.id, r); return [...seen.values()].sort((a, b) => a.id.localeCompare(b.id)); };
  return { directWrites: dedupe(directWrites), rpcCalls: dedupe(rpcCalls) };
}

// ---------------------------------------------------------------------------
// 9. Compose the deterministic inventory + the identity set the test diffs on.
// ---------------------------------------------------------------------------
function main() {
  const mig = scanMigrations();
  const edge = scanEdgeFunctions();
  const browser = scanBrowser(mig.reachesValueNames);

  const identities = [];
  for (const w of mig.dbWriters) identities.push({ id: w.id, value_impact: w.value_impact, surface: 'db_function' });
  for (const w of mig.dbDelegators) identities.push({ id: w.id, value_impact: true, surface: 'db_delegating_entrypoint' });
  for (const t of mig.triggers) if (t.writes_any) identities.push({ id: t.id, value_impact: t.writes_value, surface: 'db_trigger' });
  for (const b of mig.backfills) identities.push({ id: b.id, value_impact: b.value, surface: 'db_backfill' });
  for (const f of edge) for (const w of f.direct_writes) identities.push({ id: w.id, value_impact: VALUE_TABLES[w.table]?.value ?? false, surface: 'edge_write' });
  for (const w of browser.directWrites) identities.push({ id: w.id, value_impact: w.value_impact, surface: 'browser_write' });
  for (const r of browser.rpcCalls) identities.push({ id: r.id, value_impact: r.reaches_value_writer, surface: 'browser_rpc' });
  identities.sort((a, b) => a.id.localeCompare(b.id));

  const inventory = {
    tool: 'scripts/ps0/discover-writers.mjs',
    surfaces_scanned: { migrations_dir: 'supabase/migrations', edge_functions_dir: 'supabase/functions', browser_files: BROWSER_FILES },
    value_table_registry: Object.fromEntries(Object.entries(VALUE_TABLES).sort((a, b) => a[0].localeCompare(b[0]))),
    stored_value_tables_present: mig.forbiddenFound.sort((a, b) => a.table.localeCompare(b.table)),
    counts: {
      db_function_writers: mig.dbWriters.length,
      db_function_writers_value: mig.dbWriters.filter((w) => w.value_impact).length,
      db_delegating_entrypoints: mig.dbDelegators.length,
      db_triggers_total: mig.triggers.length,
      db_triggers_reaching_value: mig.triggers.filter((t) => t.writes_value).length,
      migration_backfills: mig.backfills.length,
      edge_functions: edge.length,
      edge_direct_value_writes: edge.reduce((a, f) => a + f.direct_writes.length, 0),
      browser_direct_writes: browser.directWrites.length,
      browser_direct_value_writes: browser.directWrites.filter((w) => w.value_impact).length,
      browser_rpc_call_sites: browser.rpcCalls.length,
      browser_rpc_reaching_value: browser.rpcCalls.filter((r) => r.reaches_value_writer).length,
      identities_total: identities.length,
      identities_value_impact: identities.filter((i) => i.value_impact).length,
    },
    db_writers: mig.dbWriters,
    db_delegating_entrypoints: mig.dbDelegators,
    triggers: mig.triggers,
    migration_backfills: mig.backfills,
    edge_functions: edge,
    browser_direct_writes: browser.directWrites,
    browser_rpc_calls: browser.rpcCalls,
    discovered_identities: identities,
  };

  process.stdout.write(JSON.stringify(inventory, null, 2) + '\n');
}

main();
