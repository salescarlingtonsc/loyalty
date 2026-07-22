# Supabase advisor triage — gadpooereceldfpfxsod — 2026-07-22

Machine-readable companion: `docs/launch/ADVISOR_TRIAGE_2026-07-22.json` (every finding, classification,
and rationale — this document is the narrative walkthrough of the same data).

**Method:** `get_advisors(type=security)` and `get_advisors(type=performance)` pulled live against
`gadpooereceldfpfxsod`, cross-checked with live read-only catalog SELECTs (`pg_proc`, `pg_namespace`,
`pg_class.reltuples`, `pg_policies`, `has_function_privilege`, `has_table_privilege`,
`pg_get_functiondef`) — no write, no DDL, and no customer-data row was selected. All counts below match
the two advisor pulls exactly and match `docs/launch/PRODUCTION_READINESS_REVIEW_2026-07-22.md`'s
headline figures (161 security notices, 368 performance notices).

## Headline numbers

| | Total | Accepted-by-design | Needs-fix (non-blocking) | Launch-blocking |
|---|---:|---:|---:|---:|
| Security | 161 | 48 | 1 | 0 individually — 113 are covered by the already-tracked `P0-RLS-GRANTS-004` gate |
| Performance | 368 | 280 (261 FK + 19 unused-index) | 88 (87 policy + 1 auth-connection) | 0 |

No advisor finding, taken alone, is a new launch blocker beyond what `launch-blockers.json` already
tracks. The one place this triage materially sharpens the picture is `P0-RLS-GRANTS-004`: the 113
"authenticated can execute a SECURITY DEFINER function" warnings are not noise and not individually
dangerous — they are the precise inventory of what that gate's adversarial suite has to prove safe at
runtime.

## Security — SECURITY DEFINER executable findings

**161 total: 47 INFO `rls_enabled_no_policy`, 113 WARN `authenticated_security_definer_function_executable`,
1 WARN `anon_security_definer_function_executable`.**

### Anon-executable SECURITY DEFINER (1 of 1) — ACCEPTED-BY-DESIGN

`public.get_customer_phone_otp_capabilities()` is the only `SECURITY DEFINER` function in the exposed
`public` schema callable by `anon`. Its body (pulled via `pg_get_functiondef`) takes no arguments,
touches no table, and returns exactly `{"sms": bool, "whatsapp": bool}` derived from
`app.platform_feature_enabled()`. No PII, no side effect, no per-input oracle (it takes no input at
all). This is a deliberate public capability-discovery endpoint — accepted.

### Authenticated-executable SECURITY DEFINER (113 of 113) — ACCEPTED-BY-DESIGN-PENDING-P0-RLS-GRANTS-004

This is the platform's whole architecture, not a leak: every module (sales, points, credit, gift cards,
bookings, staff, billing) writes through an `authenticated`-callable `SECURITY DEFINER` RPC that is
*expected* to check tenant/staff/role ownership internally, because RLS alone cannot express every
cross-table check these flows need. Two things a catalog read can and cannot prove:

- **Can prove, and did:** 0 of 253 `SECURITY DEFINER` functions across `public`+`app` lack a pinned
  `search_path` (checked every one via `proconfig`). The classic search-path-hijack class is closed
  fleet-wide — this alone resolves what would otherwise be the highest-value single fix in this list.
- **Cannot prove:** that each function's body actually enforces tenant ownership for the caller's own
  `business_id`/`staff_id` before acting. That is exactly what `db/tests/rls_adversarial_isolation.sql`
  and `db/tests/v21_security_hardening.sql` exist to prove at runtime with real `SET ROLE` /
  `request.jwt.claims` principals — see `docs/launch/evidence-plan/P0-RLS-GRANTS-004.md`. Disposition:
  architecturally accepted as a class; individually launch-blocking only in the sense that
  `P0-RLS-GRANTS-004` is already `BLOCKED` and this warning set is precisely its scope. This is not a new
  finding on top of that gate.

For a first manual spot-check ahead of the full adversarial run, the functions worth reading closest are
the ones with direct ledger/financial blast radius — the full name list is in the JSON companion under
`security.authenticatedExecutableSecurityDefiner.priorityForManualSpotCheckAheadOfTheAdversarialSuite`
(functions whose names contain `sale`, `payment`, `credit`, `point`, `refund`, `revers`, `commission`,
`gift_card`, `billing`, `redeem`, `reward`, `referral`, `membership`, `subscription`, `super_admin`, or
`*_invite`).

### RLS enabled / no policy (47 of 47)

Split 40 in `public` (the PostgREST-exposed schema), 7 in `app` (internal, not exposed). For each, RLS
with zero policies means Postgres denies every row by default (fail-closed) regardless of any table
grant. To go one step further than the advisor itself, every one of the 47 was cross-checked for actual
table-level `SELECT`/`INSERT` grants to `anon`/`authenticated`:

- **46 of 47 — ACCEPTED-BY-DESIGN, confirmed RPC-only.** Zero table-level grants to `anon` or
  `authenticated` *in addition to* zero policies — doubly fail-closed. These are internal
  state/operation-log tables (`app.appointment_booking_operations`, `app.booking_management_tokens`,
  `app.public_gateway_rate_limits`, `public.customer_in_app_inbox_*`, `public.loyalty_redemption_*`,
  `public.customer_link_*`, `public.birthday_program_*`, etc.) meant to be reached only through
  `SECURITY DEFINER` RPCs. Full per-table list with the live grant check is in the JSON companion
  (`security.rlsEnabledNoPolicy`).
- **1 of 47 — NEEDS-FIX (low priority, not launch-blocking): `public.leads`.** RLS is enabled with zero
  policies (so today it returns zero rows to anyone), but the table still carries a standing
  `SELECT` grant to both `anon` and `authenticated`. That grant is currently inert, but it is unnecessary
  exposed surface — a future policy added without full review, or RLS being disabled by mistake, would
  activate it immediately. Recommend revoking the unused grant for defense in depth; not urgent since RLS
  fail-closes it today.

## Performance — ranked findings

**368 total: 261 INFO `unindexed_foreign_keys`, 87 WARN `multiple_permissive_policies`, 19 INFO
`unused_index`, 1 INFO `auth_db_connections_absolute`.**

### Unindexed foreign keys (261 findings across 100 tables)

**Current realtime risk is LOW.** This is a pre-launch database: the busiest sampled table (`sales`)
estimates **10 rows** via `pg_class.reltuples`; most tables sampled at 0-8 rows, and dozens have never
been analyzed (`reltuples = -1`). No query is slow today. The real question is workload shape at scale,
not current pain.

**Top 15 tables by unindexed-FK count** (full list of all 100 is in the JSON companion):

| Table | Unindexed FKs | Tier |
|---|---:|---|
| `loyalty_redemption_provenance` | 7 | Pre-launch |
| `credit_tenders` | 6 | Pre-launch |
| `customer_birthday_redemptions` | 6 | Deferrable |
| `sale_reversal_payment_links` | 6 | Pre-launch |
| `sales` | 6 | Pre-launch |
| `appointments` | 5 | Pre-launch |
| `cash_drawer_movements` | 5 | Pre-launch |
| `customer_birthday_entitlements` | 5 | Deferrable |
| `customer_in_app_inbox_events` | 5 | Deferrable |
| `customer_in_app_inbox_sync_operations` | 5 | Deferrable |
| `customer_link_audit_events` | 5 | Deferrable |
| `loyalty_redemption_batch_drains` | 5 | Pre-launch |
| `loyalty_redemption_reversals` | 5 | Pre-launch |
| `payments` | 5 | Pre-launch |
| `reward_grants` | 5 | Pre-launch |

**Recommendation — create pre-launch:** covering indexes for the unindexed FK columns on the
ledger/financial/booking hot-path tables: `sales`, `payments`, `cash_drawer_movements`, `credit_ledger`,
`credit_tenders`, `points_ledger`, `points_batches`, `appointments`, `reward_grants`,
`sale_reversal_payment_links`, `sale_reversal_audits`, `loyalty_redemption_provenance`,
`loyalty_redemption_reversals`, `loyalty_redemption_batch_drains`, `gift_cards`,
`gift_card_issue_operations`, `customer_links`, `customer_link_claim_attempts`, `financial_operations`,
`loyalty_redemptions`. These are exactly the tables named in `P0-FINANCE-REVERSAL-005`'s and
`P0-REPORTING-SCALE-006`'s own success criteria, so indexing them now directly de-risks two gates that
are already launch-blocking for other reasons.

**Recommendation — defer:** everything else (configuration/version-history tables, audit-log/append-only
tables, per-staff schedule/lookup tables, idempotency-key "`*_operations`" tables normally queried by
their own unique key rather than the FK in question). Creating an index nobody queries yet just adds
write overhead for no read benefit — see the "unused index" findings below for direct evidence of that
exact failure mode already happening once in this project.

### Multiple permissive policies (87 findings across 67 tables) — NEEDS-FIX, low priority, deferrable

Two distinct patterns, verified by reading the actual `pg_policies` rows for a sample:

- **83 of 87 — the deliberate v14 super-admin overlay.** A `<table>_sa_read` policy
  (`app.is_super_admin()`) sits alongside the table's normal tenant policy for the same role+action —
  matches `CLAUDE.md`'s documented "46 SELECT-only `<t>_sa_read` policies" design exactly. Verified for
  `loyalty_programs`/`loyalty_tiers`/`loyalty_rewards`/`loyalty_redemptions`: both policies are
  `PERMISSIVE`, meaning Postgres already combines them with logical OR — merging them into one policy
  with an OR'd `USING` clause is mathematically equivalent and would only save a per-row predicate
  evaluation. **Consolidation is safe but low-value**; it also loses the audit clarity of having the
  super-admin path named and reviewable separately. Recommend deferring until real query volume makes
  the overhead measurable.
- **4 of 87 — a genuine redundancy, worth fixing:** `client_field_definitions`, `client_field_options`,
  `client_field_values` each have an `_owner_read` policy alongside an `_owner_write` policy that also
  covers `SELECT` (a `FOR ALL`/`WITH CHECK`+`USING` policy implicitly counts for `SELECT` too); and
  `subscriptions` has `subscriptions_sa_write` alongside `subscriptions_select`. Unlike the super-admin
  overlay, these are two independently authored policies for the *same* owner scope, not two
  intentionally distinct principals. **Safe, straightforward consolidation candidate** — merge each pair
  into one `FOR ALL` policy with no access-scope change, whenever convenient; not launch-blocking.

Also worth noting: `loyalty_programs` and `loyalty_tiers` grant `SELECT` to `anon` at the table level,
with an RLS policy `app.is_salon_member(business_id)` gating it. That function checks
`staff.user_id = auth.uid()`, which is always `NULL`/false for an anonymous request — so, like
`public.leads` above, the `anon` grant on these two tables is currently inert but unnecessarily broad.
Same recommendation: revoke the standing `anon` grant since RLS already fail-closes it; low priority,
not launch-blocking.

### Unused indexes (19 findings) — ACCEPTED-BY-DESIGN / DEFERRABLE

Every one of these (on `points_batches`, `credit_ledger`, `referrals`, `gift_cards`, `appointments`,
`loyalty_reward_versions`, `client_packages`, `payments`, `cash_drawer_movements`, `booking_requests`,
`booking_management_tokens`, `sales`, `memberships`) supports a query shape the product will need once
it has real traffic (payroll/commission reports, branch-scoped drawer lookups, actionable-wallet
filters, membership status lookups) — they are unused because the database has near-zero rows and no
real usage yet, not because the index is unnecessary. Dropping indexes pre-launch on a zero-traffic
signal would be premature. Revisit this specific list after the `P0-POST-CUTOVER-SMOKE-016` monitoring
window, once real usage exists to judge them by.

### Auth DB connection strategy (1 finding) — NEEDS-FIX, low priority

Supabase Auth's DB connection allocation is absolute (currently capped at 10) rather than
percentage-of-instance. Harmless at today's load; switch to percentage-based before any future compute
resize, or the resize silently won't help Auth throughput. Not launch-blocking.

## What this triage does not do

It does not modify any policy, grant, index, or function — every recommendation above is a proposal for
the release owner to act on, and every "ACCEPTED-BY-DESIGN" and "NEEDS-FIX" call is a classification,
not a change. Nothing here flips any `launch-blockers.json` status; see
`docs/launch/evidence-plan/P0-RLS-GRANTS-004.md` for how the one item that actually matters for launch
(the 113-function class) gets closed with real runtime evidence.
