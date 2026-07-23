# PS-1B (events, entitlement execution, outbox+capture, referral shadow) — independent review verdict

**Reviewer independence.** I did not author any PS-1B artifact. I have no stake in PS-1B
passing. This verdict stands in for the owner's independent-reviewer ("Sol") gate and is
grounded in the committed artifacts and the real schema under `supabase/migrations/*.sql`,
verified by reading the code, tracing the value-safety paths, and running the Node gates and
greps myself.

- **Commit reviewed:** `52650145b143bd70b94bb16a5824d3297bec88ca`
  (branch `codex/phase0-transaction-foundation`, HEAD; parent/diff-base `2716f65`; tree clean).
- **Date:** 2026-07-24.
- **Runtime division:** I cannot run `psql`. I read every SQL path and mapped each suite
  assertion to a requirement; I **rely on the coordinator's rehearsal for runtime evidence**
  (fresh 90/90 canonical replay of the final bytes, v56 suite PASS, full matrix 49/49 pristine,
  concurrency harness PASS with one materialised + one replayed and committed_cents=1500) — that
  division is per house process. Everything runnable from Node I ran: `npm run validate`
  (452/452 + build), `ps0-no-executor` (7/7), `ps0-writer-registry` (7/7, 0 missing/0 stale),
  `git diff --check` clean, secret scan clean, mirror byte-identical.

---

## Per-requirement verdict

| # | Requirement | Result | Key evidence (file:line, supabase mirror) |
|---|-------------|--------|--------------------------------------------|
| 1 | Owner-letter conformance (no PS-1C/PS-2; comms synthetic-only; legacy authoritative; shadow never writes fulfilment/value) | **PASS** | No `checkout_evaluations`/`sv_*`/top-up/discount-exec anywhere (grep empty). Comms only `event_outbox`→`run_outbox_sweep`→`captured_messages` with `recipient` hard CHECK (`v56:496-497`) and **no** http/pg_net/webhook/provider in the file. Referral stays `execution_authority='legacy_trigger'`, only `cutover_status legacy→shadow` (`v56:688`). Shadow paths (`run_referral_shadow` `v56:925`, executor else-branch `v56:878-892`) write ONLY `benefit_shadow_evaluations` + `rule_effect_log(outcome='shadow')` — never `benefit_fulfilments`, never a value table. B5 adoption fulfilment is the LEGACY referral trigger's write (`v56:576-583`). |
| 2 | Value-safety (executor's only fulfilment = grant_free_item promises; zero ledger/tender/discount; redemption promise-state) | **PASS** | The sole fulfilment branch is `grant_free_item AND v_auth='studio_executor' AND v_cut='studio'` → `program_entitlements` + `benefit_fulfilments` + budget reservation (`v56:844-876`); every value-moving effect falls to the shadow else-branch. **Zero** `insert into credit_ledger/points_ledger/sales/gift_cards/payments/reward_grants` in v56 (grep empty). `redeem_program_entitlement`/`reverse_program_entitlement` (`v56:1034,1065`) flip status + write op-ledger + `audit_log` only — no value. |
| 3 | Contract fidelity (envelope + all UNIQUEs + state machine + promise-preservation + v33 untouched) | **PASS** | `domain_events` UNIQUE(business_id,event_type,source_operation_id,schema_version) (`v56:114`), append-only (`v56:124-134`). `rule_effect_log` UNIQUE(event_id,rule_id,effect_index) (`v56:273`) + `(outcome='fulfilled')=(benefit_fulfilment_id is not null)` (`v56:280-281`). `benefit_fulfilments` UNIQUE(business_id,canonical_benefit_key) append-only (`v56:187,198-208`). Promise preservation: existing entitlement keeps its reservation; only a NEW grant hits the cap (`v56:762-768`), `budget_reservations` append-only (`v56:336-346`). `program_entitlements` lazy UNIQUE(business_id,client_id,rule_id,period_key) (`v56:379`). `event_outbox` pending→delivering→delivered\|failed→dead_letter (`v56:474`, `run_outbox_sweep` `v56:1004-1013`), dead letters owner-surfaced (`get_studio_dead_letters` `v56:1109`). v33 `customer_notification_outbox` untouched (diff grep empty). |
| 4 | House invariants on all 11 tables (RLS+sa_read, composite FKs, browser-write revocation, definer+pinned path, append-only guards, keyed idempotent RPCs, audit) | **PASS** | Every new table has owner_read + sa_read RLS and `revoke all … grant select` (no browser write grant — grep empty). Composite tenant FKs throughout (e.g. `v56:274-277,382-385,483-484,502-505`). 27 SECURITY DEFINER / 0 INVOKER / all pinned `search_path`. Append-only guards on domain_events/benefit_fulfilments/shadow/rule_effect_log/budget_reservations/captured_messages; entitlement lifecycle guard (`v56:406-437`). Keyed idempotent redeem/reverse with key-reuse→22023 (`v56:1051-1052,1080-1081`) + `audit_log` (`v56:1060,1089`). |
| 5 | Registry transition mechanism (guard forbids DELETE + authority/identity mutation; only GUC-gated cutover advances; no runtime GUC setter; seed reborn matches one-time UPDATE) | **PASS** | Guard: DELETE forbidden, business/source_engine/**execution_authority**/key-template immutable, only the two sanctioned cutover advances under `app.ps1b_registry_transition='sanctioned'` (`v56:651-678`). The two UPDATEs never touch the authority column (`v56:688-691`). GUC set ONLY in the migration DO block (`v56:684,692`) — no runtime setter (grep confirms). Seed reborn (`v56:700-719`): referral=shadow, recurring=studio, other 8 unchanged — matches the one-time UPDATE. |
| 6 | Test coverage vs the 7 categories + synthetic CHECK + shadow md5 invariance + comparator divergence; REAL two-connection concurrency | **PASS** | Suite `v56_ps1b_events_execution.sql` covers replay (§3/§4), idempotency (§4/§7), permission (§11, incl. corrected non-SA cross-tenant), dead-letter (§9), promise-preservation (§5), double-fulfilment (§6, studio + cross-engine), synthetic-recipient CHECK (§8/§9), shadow-never-writes via before/after md5 on value tables (§10), comparator divergence (§10). Concurrency is a genuine two-connection race (`v56_ps1b_concurrency.sh:60-85`): workers A&B race the same grant, assert exactly 1 entitlement / 1 reservation / committed_cents=1500. |
| 7 | Gates (PS-GATES flips PS-1B only; tripwire forbids PS-1C/PS-2 + captured_messages synthetic; ledger-guard untouched, deferred to PS-1C) | **PASS** | PS-GATES: `PS-1B: yes`, PS-1C/PS-2/PS-3+ `no`; captured_messages "may NEVER hold a non-synthetic recipient". `ps0-no-executor` 7/7 adds the captured_messages synthetic tripwire and still forbids `checkout_evaluations`/`sv_*`. `app.loyalty_ledger_write_guard` is **not modified** by the diff (only referenced in PS-GATES docs as deferred to PS-1C). |
| 8 | Producer wiring honesty (5 additive AFTER triggers; deferred producers documented; cannot break the legacy source txn) | **PASS** | Five AFTER triggers: sale.completed (`v56:551`), referral.qualified (`v56:588`), membership.renewed (`v56:607`), points.redeemed (`v56:624`), birthday.activated (`v56:643`). `emit_domain_event` is a single ON CONFLICT DO NOTHING insert (`v56:152-159`). The referral trigger is two inserts (emit + the B5 adoption), both ON CONFLICT DO NOTHING; its `benefit_fulfilments.config_version_id` is fed from the credit_ledger row, which is stamped non-null by the pre-existing BEFORE trigger `app.stamp_config_version` (v26), so the adoption cannot NOT-NULL-break the legacy referral reward. The `domain_events.event_type` CHECK enumerates the full future vocabulary; only five producers are wired — documented. |

**Review-round fixes — all sound, not papered over:**
- **retail_price_cents:** `products.retail_price_cents` genuinely exists (`frenly_init.sql:70`, `not null default 0`); `ps1b_catalog_price` reads it in a per-branch statement so a defect in one catalog can't zero the other (`v56:44-59`); the v56 suite drives real economics through a `service` catalog ref, so the cap/promise tests exercise a non-zero face.
- **ON CONFLICT ON CONSTRAINT** name form for the reservation insert avoids the plpgsql OUT-param (`entitlement_id`) column-name capture (`v56:790`).
- **budget_reservation_id write-once** in the lifecycle guard (null→value linking allowed, then immutable) (`v56:418-422`).
- **redeemed→reversed** sanctioned transition in both guard and RPC (`v56:428-431,1085`).
- **key-reuse→22023** in redeem/reverse (`v56:1051-1052,1080-1081`).
- **seed reborn** post-PS-1B (`v56:700-719`).
- **non-SA cross-tenant principal:** the suite creates a fresh non-SA owner of business B for the denial test (fixture owner B is a sanctioned super-admin) and separately confirms SA v14 read-everything still holds (`v56 suite §11`).

---

## Findings

No BLOCKING, no CHANGES-REQUIRED findings. Two NOTE-level observations, neither affecting
value-safety, contract fidelity, or owner-letter conformance:

- **N1 (NOTE) — dead fallback in the free-item face computation.** In `ps1b_execute_event`
  the face value is `coalesce(app.ps1b_catalog_price(...), nullif(amount_cents,'')::int, 0)`
  (`v56:850-851`), but `ps1b_catalog_price` returns `0` (never NULL) for a null/absent catalog
  ref (`v56:49,55,57`), so the `amount_cents` middle arm is unreachable. This is harmless today
  because `grant_free_item` always carries a catalog ref (PS-1A's `ps1a_catalog_ref_valid`
  enforces it at authoring), so the face is always the catalog price. If a future effect wants a
  bare-amount free item, this arm would silently yield 0 — worth tightening (return NULL on
  no-ref) when that path is introduced.
- **N2 (NOTE) — defensive `exception when others then return 0`** remains in
  `ps1b_catalog_price` (`v56:58`). It is now benign (the referenced columns exist and each
  branch is a single statement, so the original whole-statement plan-swallow cannot recur), and
  it correctly prevents a malformed catalog ref in the cron executor from zeroing unrelated work.
  Recorded only so a future column rename to a *referenced* catalog table is known to be
  re-swallowed here — pair any such rename with a direct test of the price path.

Both are non-blocking. The producer coupling (req 8) and the cron-scheduled executor/outbox/
shadow jobs were scrutinised and cleared: they create promises, shadow logs, and synthetic
captures only — no customer value moves and no real message is ever sent.

---

## OVERALL VERDICT: **PASS PS-1B**

Every clause of the owner's PS-1B authorization is met, and every contract of record
(§6/§7/§11/§15/§17 PS-1B row/§18, EVENT_CONTRACT, BENEFIT_REGISTRY_CONTRACT, PS-GATES) is
honoured. The executor moves **no customer value** — its only fulfilment is a `grant_free_item`
promise gated on `studio_executor`+`studio` authority, with every value-moving effect
shadow-logged; entitlement redemption is promise-state only; comms flow exclusively through the
new outbox into a synthetic-only capture provider with no real transport anywhere; the referral
engine stays legacy-authoritative with only a `legacy→shadow` cutover, and the shadow evaluator
and comparator never write a live fulfilment or a value table. All eleven new tables carry the
house invariants; the registry transition is a controlled, GUC-gated, authority-immutable
migration with no runtime path; the seven required test categories plus the synthetic-recipient
CHECK, shadow md5-invariance, comparator divergence, and a real two-connection concurrency race
are covered; PS-GATES authorizes PS-1B only while the tripwire keeps PS-1C/PS-2 and the
ledger-guard scopes locked; and the full gate is green (validate 452/452, no-executor 7/7,
writers 0 missing/0 stale, diff-check and secret scan clean, mirror byte-identical). The named
review-round fixes are all substantively correct.

Per the owner's process, PS-1B is accepted for its authorized scope (UAT apply of the event/
execution/outbox/shadow foundation). PS-1C checkout financial effects, PS-2 stored value, the
studio ledger-guard scopes, and production customer activation remain **out of scope and
gated** (`PS-1C+: authorized: no`; production apply still requires `RELEASE APPROVED`).

I did not modify any file other than this verdict, and I did not commit.
