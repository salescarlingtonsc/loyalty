# Peekaa audit follow-up: live authorization, drift, Auth, cron and launch evidence

**Date:** 29 August 2026  
**Production project:** `loyalty` (`gadpooereceldfpfxsod`, Singapore)  
**Mode:** read-only in production. No schedules, migrations, rows, grants, functions, secrets, accounts or deployments were changed.  
**Relationship to the main audit:** this document supplies the requested deeper evidence and supersedes the affected statements in `SECURITY-CRON-LAUNCH-AUDIT-2026-08-29.md`.

## 1. Executive result

The independent re-verification is accepted. The corrected drift set is:

- live v590, v591 and v592 migration objects that are absent from the observed `origin/main`;
- the live v361 bring-back cron schedule, which was registered manually rather than by reproducible migration SQL;
- **not v593**: v593 is reproducible from `origin/main` commit `c859fd9a` at `db/migrations/20260829_nestly_v593_package_expiry.sql`.

The deeper review strengthens SEC-01 and SEC-02, narrows SEC-09, and reduces the cron-burst concern:

- `reward_grants.status` is the only existing reward-grant column the snapshot guard permits an UPDATE to change. No sanctioned application, trigger, cron or Edge Function currently updates it. Direct browser-role UPDATE can therefore be revoked without breaking a known current workflow.
- The exhaustive live FK catalog contains **119** simple FKs without a matching same-business composite FK across **72** child tables whose parent is tenant-owned, plus **22** simple FKs in children whose tenant is derived indirectly. Most are server-only. The immediately exploitable set includes `service_products`, `appointment_services`, `booking_requests`, `change_requests`, `waitlist`, and an additional `sales` gap.
- The current callable `SECURITY DEFINER` surface is **718 unique functions**, not the earlier historical advisor snapshot of 690 authenticated plus 15 anonymous warnings. Of these, 717 are callable by `authenticated` and 15 by `anon`. The completed acceptance pass found no authorization bypass, but identified seven unnecessary anonymous grants and one genuine public demo-intake abuse risk.
- The cron start burst is primarily schedule alignment. Actual peak overlap was 15; concurrency above eight occupied approximately 4.16 seconds, or 0.000672% of the observed week. Staggering is P3 hygiene, not a capacity or launch blocker.
- `frenly-outbox-sweep` has no real delivery consumer in source, and neither its captured-message sink nor its outbox source showed activity in the last 30 days. It is safe to pause only together with, or after checking, the synthetic Program Studio producer so new pending rows are not stranded.
- The public Auth endpoint confirms email auto-confirm is enabled, so email confirmation is **off**. A subsequent read-only Management API check closed the hidden-config gap: leaked-password protection is on, Auth CAPTCHA is off, the current numeric limits are recorded below, and the redirect allowlist contains only owned Peekaa/Nestly hosts.

The launch decision remains **HOLD** for unrestricted multi-tenant release. The database-size evidence still does not justify upgrading Supabase solely because of cron history.

## 2. Corrected production/source drift and exact recovery artifacts

### 2.1 Applied live migration ledger

| Version | Live migration name | Reproducible from observed `origin/main` |
|---|---|---|
| `20260828135225` | `nestly_v590_cron_run_history_retention` | No |
| `20260828135527` | `nestly_v590_cron_run_history_retention_fn` | No |
| `20260828141250` | `nestly_v591a_webhook_consumer_markers` | No |
| `20260828141323` | `nestly_v591b_support_status_ingest_process_once` | No |
| `20260828141352` | `nestly_v591c_retention_ingest_process_once` | No |
| `20260828141416` | `nestly_v591d_retention_optout_process_once` | No |
| `20260828141459` | `nestly_v591e_sv_tender_release_no_empty_write` | No |
| `20260828141707` | `nestly_v592_support_tick_dispatcher` | No |
| v593 | `nestly_v593_package_expiry` | **Yes — commit `c859fd9a`** |

### 2.2 Every live object whose current name matches v590, v591 or v592

| Type | Exact name | State |
|---|---|---|
| Function | `app.purge_cron_run_history_v590(integer,integer,integer,integer)` | Live; `SECURITY DEFINER`; postgres execute only |
| Function | `app.v591_max_attempts()` | Live; immutable; postgres execute only |
| Function | `app.support_tick_v592()` | Live; `SECURITY DEFINER`; postgres and service-role execute |
| Cron | `nestly-v590-cron-history-retention` (job 49) | Active, `53 2 * * *` |
| Cron | `nestly-v592-support-tick` (job 50) | Active, every minute |

The v591 migrations also altered objects whose names do not contain `v591`: `app.support_ingest_status_v535(integer)`, `app.v551_ingest_retention_status(integer)`, `app.v551_ingest_retention_optout(integer)`, and `app.run_sv_tender_release(integer)`. They created `public.whatsapp_webhook_event_consumers`, whose current name likewise has no version suffix. Those objects must be mirrored too.

The exact `pg_get_functiondef` output, reconstructed marker table, constraints, grants, schedules and retirements are preserved in:

- `audit-artifacts/v590-v592-live-definitions.sql`
- `audit-artifacts/v590-v592-live-object-catalog.csv`

The separate live drift is cron job 25, `nestly-v361-bringback-issue-daily`, scheduled `20 3 * * *` UTC and running `select app.run_bringback_issue_v361();`. It had eight recent successful runs and seven live bring-back grants at inspection. **Maintain it, but register it in source.**

### 2.3 Recovery rule

Mirror the recovered definitions verbatim into both migration trees and both canonical order manifests using the real applied ledger versions. Add rollback/effective-catalog tests. Do not replay them on production and do not create a second v593.

## 3. SEC-01: exact `reward_grants` mutation boundary

The live table has 20 columns. It does **not** have `expires_at`, `redeemed_at`, quantity fields or `meta`; those names must not be assumed by the repair migration.

| Column | UPDATE through existing snapshot guard |
|---|---|
| `id` | Rejected |
| `business_id` | Rejected |
| `program_id` | Rejected |
| `client_id` | Rejected |
| `period_index` | Rejected |
| `reward_type` | Rejected |
| `reward_value` | Rejected |
| `reward_item` | Rejected |
| `status` | **Allowed**: constrained only to `granted`, `redeemed`, or `expired` |
| `granted_at` | Rejected |
| `config_version_id` | Rejected |
| `reward_snapshot` | Rejected |
| `reward_taxonomy_id` | Rejected |
| `reward_label` | Rejected |
| `fulfillment_kind` | Rejected |
| `retention_program_version_id` | Rejected |
| `period_start` | Rejected |
| `period_end` | Rejected |
| `campaign_id` | Rejected |
| `campaign_assignment` | Rejected |

The effective exposure is `authenticated` table UPDATE plus `grants_update USING (app.is_salon_member(business_id))`; `WITH CHECK` is null. There is no UPDATE audit trigger. `trg_audit_grants` runs only on INSERT.

### 3.1 Current legitimate writer inventory

| Path | Current behavior | Breakage if direct browser UPDATE is revoked |
|---|---|---|
| `public.issue_campaign_offer(uuid,uuid,uuid,text,bigint,uuid)` | Only direct INSERT writer found; validates actor, owner, retention-module permission, idempotency and campaign/business/client scope | None; it is a definer RPC and does not depend on direct browser UPDATE |
| `app.stamp_config_version()` trigger | Mutates `NEW` during INSERT | None |
| `app.snapshot_reward_grant_taxonomy()` trigger | Derives snapshot/provenance on INSERT | None |
| `app.reward_grant_snapshot_guard()` trigger | Rejects protected UPDATE changes; deliberately omits `status` | Remains useful behind future narrow state RPCs |
| `app.audit()` trigger | INSERT-only audit row | None; add explicit state-transition auditing in the fix |
| `app.bump_customer_wallet_signal_v479()` trigger | INSERT-only wallet signal | None |
| Browser application | No direct INSERT/UPDATE/DELETE path found | None |
| Edge Functions | No direct writer found | None |
| All 35 active cron commands | No direct writer found; v361 writes `bringback_grants_v361` instead | None |

### 3.2 Exact fix design

1. Drop `grants_update`.
2. Revoke direct INSERT, UPDATE, DELETE and TRUNCATE from browser roles.
3. If redemption or expiry is required now, introduce separate narrow state-transition RPCs. Each must bind `auth.uid()`, business/customer scope and allowed source state; lock the row; be idempotent; write an audit event; and pin `search_path`.
4. If no current workflow needs those transitions, ship the revoke first and add RPCs only with their feature.
5. Assert the effective ACL and owner/staff/pending/inactive/foreign-tenant matrix in a rolled-back database test.

### 3.3 Sibling legacy member-wide mutation policies

The live `pg_policies` scan found two additional residual tables beyond `reward_grants`:

- `notifications.notifications_update`: any active member can update arbitrary notification fields, including `title`, `body`, references and `read_at`. The app already uses read-state RPCs. Revoke broad direct UPDATE and allow only a narrow recipient/read-state transition. Severity: **Medium** integrity/confidentiality risk.
- `resources.resources_all`: any active member can CRUD resources. Resource scheduling is not yet fully active, which limits present impact, but `appointments.resource_id` is a simple FK. Replace with owner/module-aware policies or RPCs before enabling resource scheduling. Severity: **Medium now; High when the feature is active**.

The live v572 service, booking, waitlist and appointment-service policies now include module checks. They are not the earlier member-wide role bypasses, although their tenant-reference integrity still needs SEC-02 closure. Some name `PUBLIC` as the policy role; helper checks currently reject anonymous access, but explicit `TO authenticated` is preferable defense in depth.

Full evidence: `audit-artifacts/v590-v592-reward-grants-and-policy-scan.md`.

## 4. SEC-02: exhaustive simple-FK tenant-integrity scope

### 4.1 Live totals

| Measure | Count |
|---|---:|
| Simple FKs pointing to a parent containing `business_id` | 153 |
| Those whose child also contains `business_id` | 131 |
| Missing a matching same-business composite FK | **119** |
| Affected direct-business child tables | **72** |
| Additional indirect-tenant simple FKs where child lacks `business_id` | **22** |
| Affected tables with some authenticated DML table privilege | 14 |
| Affected tables with some anonymous DML table privilege | 7 |
| Mismatches found in the critical current-data scan | **0** |

Zero current mismatches means the sampled live data is clean; it does not prevent a future cross-tenant write.

### 4.2 Priority migration slice

| Rank | Table | Unprotected parent references | Why exploitable / existing protection | Recommended structural fix |
|---:|---|---|---|---|
| 1 | `service_products` | `service_id`, `product_id` | Authenticated Services-module DML; RLS proves local service only, not product ownership | Add immutable `business_id` and two composite FKs, or one hardened trigger/RPC |
| 1 | `appointment_services` | `appointment_id`, `service_id` | Authenticated Appointments-module DML; appointment is scoped, foreign service is not | Add child `business_id` and both composite FKs |
| 1 | `booking_requests` | `appointment_id`, `branch_id`, `service_id`, `staff_id`, `table_type_id` | v572 proves request business/module, not all referenced parents | Composite FK for every tenant-owned optional reference |
| 1 | `change_requests` | `appointment_id` | v572 proves request business/module, not appointment ownership | Composite appointment/business FK plus state-machine RPC |
| 1 | `waitlist` | `client_id`, `service_id`, `table_type_id` | v572 module checks do not prove same-business parents | Composite FKs for all three |
| 2 | `sales` | `client_id`, `appointment_id`, `product_id` | Authenticated `create_sales` INSERT policy checks sale business only; no general parent-business trigger | Add three composite FKs and a direct cross-tenant sale regression |
| 3 | `branch_breaks`, `branch_hours` | `branch_id` | Owner-only RLS reduces exploitability; browser writes still possible | Composite branch/business FK |
| 3 | `staff_hours`, `staff_off_days`, `staff_recurring_off_days`, `staff_invites` | `staff_id` | Owner-only RLS reduces exploitability | Composite staff/business FK |
| 4 | `bringback_grants_v361`, `client_packages`, `points_batches` | Tenant-owned parents | Effective RLS is read-only/server-write despite browser table ACLs | Revoke unused browser DML and assert privileges |
| 5 | Remaining server-only relationships | See machine inventory | No current browser DML path; lower immediate exploitability | Batch structural integrity after high-risk slice |

Important indirect-tenant children include `service_products`, `appointment_services`, `bundle_items`, `stock_batches`, billing-document/event children, customer-intelligence export rows and several platform accounting children. They are retained in the machine inventory rather than omitted merely because they lack a direct `business_id`.

The migration-ready machine artifact is `audit-artifacts/tenant-simple-fk-inventory-2026-08-29.csv`. It contains 141 rows and 26 columns, including every constraint, effective DML privileges, RLS state, same-business policy/trigger assessment, exploitability rank and proposed remedy.

### 4.3 Migration batching completed

The 141 rows are now partitioned exhaustively in `audit-artifacts/SEC-02-TENANT-FK-MIGRATION-BATCH-PLAN-2026-08-29.md`:

| Batch | Rows | Priority and treatment |
|---|---:|---|
| B1 | 17 | P0 browser-write closure: appointment/service, booking, change, reward-client, sales, service-product and waitlist relationships |
| B2 | 14 | P1 owner/staff/module browser-write closure: branch/staff schedules, bring-back, packages and points |
| B3 | 48 | P2 direct server-only rows whose parent composite key already exists |
| B4 | 42 | P3 direct server-only rows requiring a parent composite unique key first |
| B5 | 12 | P3 indirect-tenant children requiring an immutable derived `business_id` and unanimous-parent backfill |
| B6 | 8 | P3 pre-tenant/polymorphic lifecycle rows; retain simple identity FK and use conditional enforcement rather than a blanket composite |

Parent prerequisites are 15 READY tuples, 36 new composite unique-key tuples, and five conditional tuples across four polymorphic/pre-tenant parent tables. No inventoried relationship was proven intentionally cross-tenant.

For safe rollout, retain the old simple FK during cutover, add the new FK `NOT VALID`, test all writers and foreign UUIDs, then `VALIDATE CONSTRAINT` in a separate measured window. This reduces the validation scan in the add transaction but does not make DDL lock-free; use a short `lock_timeout`. Preserve existing NULL/`MATCH SIMPLE` and `ON DELETE` behavior unless the product contract explicitly changes.

## 5. SEC-09: callable `SECURITY DEFINER` allowlist triage

### 5.1 Current live inventory

| Measure | Count |
|---|---:|
| Non-system `SECURITY DEFINER` functions | 1,433 |
| In `public` or `app` | 1,430 |
| Callable by `anon` and/or `authenticated` | **718** |
| Callable by `anon` | 15 |
| Callable by `authenticated` | 717 |
| Direct PUBLIC EXECUTE ACL | 0 |
| Functions with a detected static write | 371 |
| Static writes without a direct auth indicator before first write | 47 |
| Those 47 with a recognized delegated auth/context helper before write | 44 |
| No-direct/no-recognized-helper prewrite candidates | **3** |

The union is 718 because 14 functions are callable by both roles. Every inventoried callable function had a pinned path in the observed form `search_path=pg_catalog, public, app, pg_temp`; the prior mutable-search-path warnings were not reproduced in this current callable slice.

### 5.2 Top slice

The prewrite sort leaves three conservative top candidates:

- `public.submit_demo_request_v292(text,text,text,text,text,text)`: intentional public INSERT, global 200/hour cap and 30-minute deduplication, but no detected Turnstile/CAPTCHA or per-IP quota. This is a **spam/cost/availability risk**, not tenant privilege escalation. Keep anonymous execute only if the demo form is required; place it behind gateway Turnstile and IP/device rate limits, add bounded retention and alerts.
- `public.report_client_error_v177(...)`: intentional public telemetry. Its `auth.uid()` is attribution after the INSERT rather than an authorization gate. SEC-04 token redaction, payload/rate caps and retention are the relevant controls.
- `public.mark_notification_read(...)`: conservative scanner result, not a no-auth write. `is_salon_member` occurs textually after the `UPDATE` token but inside that statement's `WHERE` predicate; it constrains the write.

The other 44 prewrite matches without a direct exact-token check use recognized authorization/context helpers before writing. Examples include:

- `set_sale_policy`, `open_drawer`, `record_drawer_movement` via permission helpers;
- customer inbox/feedback functions via authenticated customer-context helpers;
- `platform_complete_my_prospect_task_v89` via platform permission helpers;
- `save_loyalty_tier_draft_v143` and `business_switch_to_stamps_v384` via owner/module helpers;
- `get_period_economics_v109` via finance-scope validation.

Do not bulk-revoke these based on a token grep. Treat helper-chain verification and owning negative tests as the acceptance criterion. The complete JSON inventory records signature, raw/effective grants, volatility, pinned path, detected auth checks, write verbs, helper indicators, body hash and risk ordering:

- `audit-artifacts/sec-09-security-definer-inventory-2026-08-29.json`
- `audit-artifacts/sec-09-security-definer-top-slice-2026-08-29.md`
- `audit-artifacts/sec-09-security-definer-top-slice-2026-08-29.csv`

Final SHA-256 checksums are `57e0b4fef957f0cbda709b26f3a4bb254f3aad9c2d801ef7e35f50c2860d8abf` (JSON), `4323b9d3110cc97262cb5de6d6c052c3f947ec5cc0336f80e8c6c96133e17967` (Markdown), and `25e320a64a68e1cab8218497570772e6f2644e88e7927621404373cb340055ed` (CSV).

### 5.3 Allowlist acceptance rule

For every callable definer function, record an intended role, caller(s), direct or delegated identity check **before the first write/data return**, tenant/ownership predicate, volatility, pinned `search_path`, and an adversarial test. Revoke only functions lacking a current caller or accepted public contract. CI should fail on unexpected new callable functions or broadened grants.

### 5.4 Completed 718-function acceptance classification

| Classification | Count | Decision |
|---|---:|---|
| Accepted direct auth | 553 | Retain; bind to existing negative tests |
| Accepted delegated auth | 146 | Retain; preserve the named helper-chain contract |
| Intentional public endpoint | 8 | Retain only with input, abuse, privacy and rate-limit tests |
| Server/internal-but-exposed | 4 | Remove browser execute where no client call exists or move behind a private helper boundary |
| Needs manual review | **0** | Complete |
| Revoke candidate | **7** | Remove unnecessary `anon` execute; authenticated behavior remains internally owner/auth gated |

The seven exact anonymous grants to revoke are:

1. `public.get_workspace_locale_preference_v97()`
2. `public.set_workspace_locale_preference_v97(text,bigint)`
3. `public.business_get_catalogue_media_versions_v158(uuid)`
4. `public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text,integer,boolean)`
5. `public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text,integer)`
6. `public.business_request_manual_payment_v542(uuid,uuid,text,text)`
7. `public.business_get_manual_payment_request_v542(uuid)`

All seven reject unauthenticated use internally, so this is unnecessary surface area rather than a demonstrated bypass. Remove the grants and add `has_function_privilege('anon', ..., 'EXECUTE') = false` assertions.

Source caller verification found authenticated browser calls for both locale functions, catalogue-media versions, reward update and reward creation. Removing only `anon` preserves those paths. No direct application caller was found for the two v542 manual-payment functions; retain authenticated execute only if the manual-payment workflow is still intended.

The four internal-but-exposed functions are `public.create_business(...)` (a legacy denial stub), `app.staff_free_for_appointment_v120_base(...)`, `app.live_balance_programme_v381(uuid)`, and `app.c46_inbox_promotion_ref_v579(...)`. The source scan found no direct application RPC caller for any of the four. Revoke browser execute after confirming their definer-wrapper tests; nested owner/definer calls do not require an end-user execute grant.

The final machine classification is `audit-artifacts/sec-09-acceptance-classification-2026-08-29.json`; the reproducible classifier is `scripts/sec-09-acceptance-classify.mjs`. SEC-09 is therefore narrowed from an unknown high-risk surface to a finite ACL-hardening batch plus the already identified public-endpoint abuse controls.

## 6. Live Auth posture

The unauthenticated live `/auth/v1/settings` response was checked with the current publishable key. The hidden settings were then retrieved read-only from `GET /v1/projects/gadpooereceldfpfxsod/config/auth` through the existing authenticated Supabase CLI session. No access token or secret-valued field was printed or stored.

| Setting | Actual current evidence |
|---|---|
| Email provider | Enabled |
| Email confirmation | **Off**: `mailer_autoconfirm=true` |
| Phone provider | Enabled |
| Phone auto-confirm | Off: phone confirmation is required |
| SMS provider | Twilio Verify |
| Password signup | Enabled |
| Google OAuth | Enabled |
| Anonymous-user signup | Disabled |
| Passkeys | Enabled |
| SAML | Disabled |
| Auth CAPTCHA | **Off**: `security_captcha_enabled=false`; configured provider remains `turnstile`. Gateway Turnstile is a separate application control and remains present. |
| Leaked-password protection | **On**: `password_hibp_enabled=true` |
| Password baseline | Minimum length 6; no required character classes. Current-password and recent-reauthentication requirements for password updates are both enabled. |
| Email/OTP rate limits | `rate_limit_email_sent=2`, `rate_limit_otp=30`, `smtp_max_frequency=60s`; email OTP is six digits and expires after 3,600s |
| Phone/SMS rate limits | `rate_limit_sms_sent=30`, `sms_max_frequency=5s`; phone OTP is six digits and expires after 60s; Twilio Verify provider |
| IP-oriented verification/refresh limits | `rate_limit_verify=30`, `rate_limit_token_refresh=150`; IP forwarding is disabled, so Auth uses the direct client IP observed by Supabase |
| Recovery rate limit | Recovery shares the combined email-send ceiling of 2 and the 60-second same-recipient SMTP frequency control; no separate recovery-only numeric field is returned by the current Auth config API |
| Anonymous sign-in limit | 30, although anonymous-user signup itself is disabled |
| Redirect allowlist | **Verified live**; exact patterns listed below |

The local 60-second email and 5-second SMS interval values match the hosted project.

The exact live site URL is `https://www.peekaa.asia`. The live additional redirect patterns are:

1. `https://www.nestly.asia`
2. `https://www.nestly.asia/**`
3. `https://nestly.asia`
4. `https://nestly.asia/**`
5. `https://peekaa.asia`
6. `https://peekaa.asia/**`
7. `https://www.peekaa.asia`
8. `https://www.peekaa.asia/**`
9. `https://peekaa.asia/*`
10. `https://www.peekaa.asia/*`

The unique live hostnames are therefore exactly `www.nestly.asia`, `nestly.asia`, `peekaa.asia`, and `www.peekaa.asia`. No Vercel or Frenly hostname is present. SEC-07's unowned/legacy-host hypothesis is **not reproduced in live configuration and is closed as a current vulnerability**. The duplicate `/*` and `/**` patterns are cleanup hygiene; path wildcards on the four owned HTTPS hosts do not allow a different hostname.

The P0 Auth gate must also be amended: its old “enable email confirmation” requirement conflicts with the confirmed live auto-confirm setting. Decide and document whether password/email onboarding intentionally permits immediate confirmation, then test that chosen policy rather than silently accepting drift.

### 6.1 Newly confirmed Auth launch gaps

1. **Password baseline is below Supabase's current recommendation.** Six characters with no required character classes is weaker than Supabase's documented minimum recommendation of eight. HIBP protection substantially helps, but it does not replace length. Raise the minimum to at least 8; use 12 for business/platform password accounts where usability permits, or require passkey/MFA. Existing users need a staged reauthentication/reset plan because policy changes do not automatically rewrite passwords.
2. **Production recovery email capacity is not launch-ready.** No custom SMTP host is configured and the project-wide combined email-send ceiling is 2 per hour. That is insufficient for password recovery, security notices or a launch burst. Configure branded custom SMTP, set an appropriate bounded rate, and prove delivery, expiry, replay rejection and alerting before relying on email recovery.
3. **Email auto-confirm is an explicit risk decision.** With `mailer_autoconfirm=true`, possession of an email address is not proven at signup. If email/password accounts can acquire customer or business authority before another verified factor is bound, enable confirmation. If Google OAuth or verified phone is the mandatory trust anchor, encode and test that rule server-side.
4. **Auth CAPTCHA is genuinely off.** This is acceptable only if every externally reachable signup/sign-in/recovery/OTP route is forced through the gateway Turnstile and direct Supabase Auth endpoints cannot create material abuse or SMS/email spend. The missing evidence is a direct-endpoint bypass drill, not another configuration read.

## 7. Job 6 and cron concurrency

### 7.1 `frenly-outbox-sweep`

Live 30-day state:

| Measure | Result |
|---|---:|
| `captured_messages` total rows | 4 |
| `captured_messages` rows created in last 30 days | 0 |
| `event_outbox` total rows | 4 |
| `event_outbox` rows created/updated in last 30 days | 0 |
| `event_outbox` state | All `consumer='comms'`, all `delivered` |
| Current due backlog | 0 |

All four captures are synthetic `in_app` / `sale.completed` records dating to 23 July. Repository and Edge Function scans found no delivery consumer of `captured_messages`; its source references are test/capture-provider code. `get_studio_dead_letters` reads failed/dead outbox records, not captured messages. Query-statistics inspection found no application read of `captured_messages` in the retained statistics window other than the audit query.

**Decision:** approve a controlled pause of job 6 after checking the Program Studio producer in the same release. If producers can still enqueue `consumer='comms'`, disable that synthetic path too or replace the capture provider with a real delivery provider. Otherwise pausing only the sweep would strand future pending rows. No pause was performed in this audit.

### 7.2 Actual overlap, not start alignment

Across 41,994 retained executions from 22–29 August:

| Runtime/overlap measure | Result |
|---|---:|
| Runtime p50 | 0.0142 s |
| Runtime p95 | 0.0891 s |
| Runtime p99 | 0.1869 s |
| Maximum runtime | 2.7065 s |
| Peak simultaneous executions | **15** |
| Wall time above 8 simultaneous | ~4.158 s |
| Share of observed time above 8 | **0.000672%** |

The earlier 19-starts-in-one-second measure described alignment, not concurrency. At these runtimes, staggering does not justify a Supabase upgrade and is not a P0 gate. Keep overlap/advisory locks where duplicate execution would corrupt state; stagger jobs during routine cleanup for smoother connection/CPU demand.

## 8. Seventeen P0 gates: reuse existing evidence and run only the missing proof

The launch checker still reports 0/17 valid production-evidence artifacts. That does not mean there is no prior work; it means prior/local evidence is not hash-pinned proof for the final production SHA. Reuse the controls and harnesses below, and rerun only the missing exact-release/runtime part.

The machine-readable execution map, including precise reusable paths, invalidation conditions, external access needs and estimated rerun durations, is `audit-artifacts/p0-launch-gate-evidence-map-2026-08-29.csv`.

| Gate | Existing evidence to reuse | Missing proof only |
|---|---|---|
| P0-CUTOVER-PARITY-001 | Canonical replay/materialization tooling; source/live catalog reads; July local replay closed; current drift recovery artifacts | Mirror v590–v592 and v361; replay frozen source; exact source/live migration, object and cron parity |
| P0-PUBLIC-ABUSE-002 | Public gateway tests passed 26/26; v21 abuse contracts 9/9; origin/rate/Turnstile validation exists | Hostile-origin, burst, duplicate and direct-PostgREST bypass drill against real gateway; logs free of PII |
| P0-BOOKING-TOKEN-003 | SHA-256 token storage, expiry, replay, identity and idempotency source/SQL tests; token table RLS/no browser grants | Production lifecycle: valid use, replay, expiry, missing/wrong token and wrong-identity denial |
| P0-RLS-GRANTS-004 | v572 policy regression; `GOLIVE_SECURITY_GATE` 49 passes; live policy/ACL scans; earlier two-tenant harness design | Close SEC-01/02/09; run effective owner/staff/pending/inactive/anon/foreign-UUID matrix on final schema |
| P0-FINANCE-REVERSAL-005 | v20/v40 accounting contracts; correctness and race harnesses; prior `V49A` local rehearsal evidence | Current-chain disposable DB concurrency plus full refund/over-refund/replay/direct-table-denial reconciliation |
| P0-REPORTING-SCALE-006 | Reporting-scale suite 8/8, including pagination, bounds and SGT logic | Representative >1,000-row tenants, query plans/durations, and targeted advisor-index triage |
| P0-PDPA-OPERATIONS-007 | Legal/consent model and pages; PDPA suite 5/5; request/incident operating document | Name DPO/privacy, retention and incident owners; rehearse access/deletion/incident workflow with timings |
| P0-AUTH-EMAIL-008 | Recovery non-enumeration source tests; passkey/phone/password code; gateway Turnstile tests; full live Auth configuration captured read-only, including rates, HIBP, CAPTCHA and redirects | Choose confirmation policy; strengthen password baseline; configure custom SMTP; signup/recovery mailbox, direct-endpoint abuse and session-revocation drills |
| P0-NOTIFICATIONS-009 | Durable inbox/preferences model, RLS/RPC controls, service worker/push dispatcher and WhatsApp tests | Replace/retire synthetic comms capture; provider delivery/retry/opt-out/quiet-hour/dead-letter evidence on real devices |
| P0-PAYMENTS-SUBSCRIPTIONS-010 | Stripe command/webhook/idempotency contracts; targeted business suite 72/72; prior v124 evidence | Exact chosen live/manual model; checkout/manual payment, signature, replay, out-of-order, entitlement, refund and dead-letter reconciliation |
| P0-BACKUP-ROLLBACK-011 | Rollback runbook and migration rollback procedures exist | Dashboard PITR/backup state and timed isolated restore of DB/Auth/Storage/release compatibility; current rollback commands |
| P0-OBSERVABILITY-012 | Supabase logs accessible; `/api/build`; cron runtime/backlog audit; client error and build-identity tests | Fix SEC-04 URL redaction; named alert recipients/routes; prove delivery/escalation and caught-worker error alert |
| P0-SGT-TIMEZONE-013 | Reporting SGT boundary test; source UTC/SGT arithmetic contracts | Two-clock browser/runtime drill on exact release, including day boundary and birthday/expiry cases |
| P0-TARGET-RUNTIME-014 | Production URL/project/key pinning; runtime-config/build tests; `/api/build` contract | Deploy only after approval; verify exact SHA, headers, configured project and no-sign-in customer/business/admin smoke |
| P0-TEST-CREDENTIALS-015 | Harness keeps passwords out of command arguments; test-seam runbook exists | Dashboard/provider inventory; remove/expire test OTPs/users; rotate launch/shared credentials; secret scan final SHA |
| P0-POST-CUTOVER-SMOKE-016 | Scripted cross-role journey matrix and extensive role-specific QA documents | Must run last on exact deployed SHA: journeys, one denial per privileged surface, recovery and monitoring window |
| P0-RELEASE-BUILD-017 | Historical `npm run build`, `quality`, `validate` and bundle/header tests passed | Freeze clean SHA and rerun only final build/quality/validate; register hash-pinned production artifact |

## 9. Minimal ordered closeout

1. Mirror v590–v592 and v361 into source; verify disposable replay and catalog parity.
2. Close SEC-01, plus `notifications_update`; decide whether `resources_all` ships disabled or hardened.
3. Add the rank-1 and rank-2 SEC-02 composite tenant constraints, then batch lower-risk server-only integrity constraints.
4. Put `submit_demo_request_v292` behind public gateway abuse controls and complete the helper-chain allowlist for the remaining callable definers.
5. Decide whether Auth CAPTCHA should remain intentionally off behind gateway Turnstile, strengthen the six-character/no-class password baseline or require passkeys/MFA for sensitive roles, and document the verified live Auth settings.
6. Approve a coordinated pause of job 6 and other feature-off jobs only after producer/dependency checks; do not upgrade for start alignment.
7. Freeze one release SHA and execute only the “missing proof” column of the 17-gate table.

## 10. Artifacts and integrity

- `audit-artifacts/v590-v592-live-object-catalog.csv`
- `audit-artifacts/v590-v592-live-definitions.sql`
- `audit-artifacts/v590-v592-reward-grants-and-policy-scan.md`
- `audit-artifacts/tenant-simple-fk-inventory-2026-08-29.csv`
- `audit-artifacts/SEC-02-TENANT-FK-MIGRATION-BATCH-PLAN-2026-08-29.md`
- `audit-artifacts/sec-09-security-definer-inventory-2026-08-29.json`
- `audit-artifacts/sec-09-security-definer-top-slice-2026-08-29.md`
- `audit-artifacts/sec-09-security-definer-top-slice-2026-08-29.csv`
- `audit-artifacts/sec-09-acceptance-classification-2026-08-29.json`
- `scripts/sec-09-acceptance-classify.mjs`
- `audit-artifacts/p0-launch-gate-evidence-map-2026-08-29.csv`

No production change was made while producing this report.
