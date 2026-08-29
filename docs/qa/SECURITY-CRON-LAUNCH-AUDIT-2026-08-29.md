# Peekaa Security, Cron, Disk and Launch-Readiness Audit

**Audit date:** 29 August 2026  
**Production project:** `loyalty` (`gadpooereceldfpfxsod`, Singapore)  
**Mode:** Read-only. No schedules, rows, migrations, secrets, accounts, or deployments were changed.  
**Decision:** **Launch blocked until the open P0/P1 security findings are closed. A Supabase upgrade is not justified by current database size alone.**

> **Follow-up correction and deeper evidence:** `SECURITY-CRON-FOLLOWUP-2026-08-29.md` supersedes the affected drift, SEC-01, SEC-02, SEC-07, SEC-09, outbox, cron-concurrency and 17-gate evidence statements below. In particular, v593 is reproducible; the drift is v590-v592 plus the manual v361 schedule. Nineteen starts in a second did not mean 19 concurrent executions.

## 1. Executive assessment

The application has substantial security controls and its active cron jobs are currently completing successfully. The launch risk is not a general system failure; it is a smaller set of specific authorization, tenant-integrity, privileged-access, observability, and release-drift defects.

The cron concern was real. Before v590, `cron.job_run_details` had grown to roughly 144,000 rows without retention. The new purge removed about 107,000 historical rows. The table remains 26 MB because PostgreSQL retains deleted space for reuse until a table rewrite returns it to the filesystem.

Current storage evidence does **not** show a database that needs a paid capacity upgrade:

| Measurement | Observed |
|---|---:|
| PostgreSQL database | 148,802,707 bytes (about 142 MB) |
| `cron.job_run_details` | 26 MB; about 37,415 live rows |
| WAL directory | 160 MB |
| WAL retained by replication slots | 56 bytes per active slot; not a retention problem |
| Supabase Storage object payloads | about 88 MB across 61 objects |
| Active cron jobs | 35 |
| Cron history generated in the sampled seven days | 41,135 rows, including recently retired jobs |
| Cron failures in the sampled seven days | one retired/incorrect cleanup invocation; current replacement succeeds |
| Peak jobs starting in one second | 19, on 926 sampled seconds; actual peak overlap was 15 |

For comparison, current Supabase documentation states that Free projects become read-only at 500 MB of database size. At 142 MB, this project is around 28% of that database-size ceiling. Paid projects start with an 8 GB database disk. The dashboard's provisioned disk, compute, and billing views should still be checked, but capacity alone does not currently justify an upgrade.

### Recommended launch position

1. Fix direct authenticated updates to `reward_grants`.
2. Close remaining cross-tenant foreign-key integrity gaps.
3. Enforce superadmin MFA/AAL2 inside privileged server boundaries.
4. Reconcile production-only migrations and schedules back into source control.
5. Disable completed or feature-disabled cron workers.
6. Add effective-schema, queue-productivity, and security monitoring.
7. Re-run the full two-tenant adversarial suite against the exact release schema.

## 2. Evidence and limitations

Evidence was taken from:

- the current working tree;
- `origin/main`;
- production `cron.job`, `cron.job_run_details`, PostgreSQL catalog, table statistics, WAL metadata, constraints, RLS policies, and aggregate queue counts;
- production Supabase security and performance advisors;
- targeted customer, business, platform and security test suites;
- current Supabase Cron, disk-size, upgrade, and security documentation.

The local checkout was 319 commits behind `origin/main` and contained unrelated uncommitted work. Production contains v590-v592 migrations that are not reproducible from the observed `origin/main`; v593 is reproducible from `origin/main` commit `c859fd9a` and is not part of the drift. Findings based only on old migration text were therefore rechecked against effective production policies before inclusion.

No intrusive exploit was attempted. No production identity was switched and no destructive query was run.

## 3. Integrated view-by-view assessment

This section joins the earlier customer, business and superadmin reviews to the live-database and cron findings in this report. Static/source tests prove that expected controls exist in code; they do not replace authenticated browser, REST and database attacks against the exact release build.

### 3.1 Customer view

**Current position:** Functionally mature and generally well scoped, but not yet launch-proven under hostile runtime input and abuse load.

**Controls that held in review:**

- customer wallet readers bind identity and business scope server-side;
- join tokens are hashed and verified rather than trusted from the browser;
- public application and gateway paths include origin validation, request validation, rate limiting and Turnstile controls;
- targeted customer authentication, IDOR and security contracts passed **63/63**;
- the broader customer wallet, module and public-gateway suites passed **894/895**. The one failure was a localization-marker/source-fixture mismatch, not a demonstrated authorization bypass.

**Open launch risks:**

1. Full URLs can enter telemetry (`SEC-04`), potentially retaining invite, recovery, OAuth or redemption tokens.
2. Redemption intents need a per-customer pending cap and abuse cleanup (`SEC-05`).
3. The legacy classic redemption kind remains server-callable (`SEC-06`).
4. Hosted Auth configuration is now verified: HIBP is on, Auth CAPTCHA is off, email auto-confirm is on, and the exact limits are in the follow-up. The remaining risk is direct-Auth bypass of gateway Turnstile, a six-character/no-class password baseline, and built-in recovery email capacity of only two sends per hour without custom SMTP.
5. `persistSession` plus an implicit browser flow increases the impact of same-origin XSS. The near-term requirement is strict output encoding and a stronger CSP; the longer-term target is PKCE and, where practical, an HttpOnly BFF/session boundary.
6. The global anonymous telemetry ceiling can itself suppress diagnostics during an incident. Separate operational telemetry protection from user-action throttles and monitor dropped events.

**Required proof:** hostile stored-value rendering in browser; token-redaction assertion; OTP/credential abuse drill; known-UUID cross-tenant REST tests; mobile route/session recovery; and exact-release customer booking, earn and redemption journeys.

### 3.2 Business view

**Current position:** The main UI contracts and Stripe plumbing are strong, and the most serious earlier member-wide table-policy defects are closed in live v572. Two database integrity issues still block multi-tenant launch.

**Controls that held in review:**

- **72/72** targeted business security-hardening, Stripe readiness, PayNow/POS, invite, branch-billing and Supabase-load regression tests passed;
- Stripe command paths validate authenticated users, method/body/UUID inputs, idempotency and server-side price authority;
- Stripe webhook paths verify signatures and live mode and use a durable inbox/idempotent processing model;
- staff invite acceptance validates identity/email and creates pending access rather than immediate unreviewed membership;
- branch creation is owner/payment controlled;
- live v572 replaced the earlier member-wide mutation policies for services, waitlist, service branches, service products, booking requests, change requests and appointment services.

**Open launch risks:**

1. Active staff can still directly change reward-grant state (`SEC-01`).
2. Several child tables can accept foreign-tenant UUID relationships because same-business ownership is not structurally enforced (`SEC-02`).
3. Client-side module checks are usability controls, not authorization. Every direct `.from(...).insert/update/delete` path must remain covered by effective RLS/table-privilege tests.
4. Runtime stored-XSS, CSV/formula injection, malicious file/SVG upload and large-import tests have not been completed against realistic tenant data.
5. Payment success needs a final live-mode reconciliation drill: command, webhook signature, replay, out-of-order delivery, poison event, entitlement projection, refund/reversal and dead-letter alert.

**Required proof:** two-business owner/staff/module matrix at the REST/database boundary; cross-tenant composite-FK regression; hostile-input browser suite; and exact-live Stripe reconciliation evidence.

### 3.3 Superadmin/platform view

**Current position:** No direct browser self-promotion path was found, but password-only privileged access and the large callable privileged-function surface make the platform console a launch blocker.

**Controls that held in review:**

- **62** targeted platform/security source tests passed;
- the `super_admins` table exposes no ordinary browser write/self-promotion policy;
- reviewed finance/platform RPCs check superadmin membership;
- later migrations close previously identified delegated-scope defects.

**Open launch risks:**

1. Superadmin AAL2/MFA is not enforced inside each privileged server boundary (`SEC-03`).
2. The current live catalog has 718 unique `SECURITY DEFINER` functions callable by `anon` and/or `authenticated` (717 authenticated, 15 anonymous), requiring an explicit allowlist audit (`SEC-09`).
3. Broad CSP rules increase the impact of credential/session compromise (`SEC-08`). The SEC-07 legacy redirect-host hypothesis was closed against live configuration.
4. Privileged recovery, MFA reset, break-glass use, session revocation, impersonation, finance actions and RLS-control actions need alerting plus tamper-resistant audit evidence.
5. A combined platform suite had one stale visual-fixture failure. It was not a demonstrated access-control failure, but the fixture must be updated and the real page rerun before acceptance.

**Required proof:** password-only superadmin denial; AAL2 success; non-admin, stale-session and recovery-path denial; every platform RPC independently checked; privileged-action alert delivery; and an emergency-access rehearsal.

### 3.4 Cross-cutting repository and release position

- The production dependency audit reported **zero known production dependency vulnerabilities**.
- The static production baseline passed in the reviewed tree.
- Source tests are valuable but several primarily assert migration/application text. The release gate must exercise effective privileges and real authenticated roles.
- Production/source drift is material: v590-v592 are live but absent from the observed `origin/main`, and one live v361 cron schedule was manually created rather than reproducibly registered. v593 is present in `origin/main` at commit `c859fd9a`.
- No production deployment, data mutation, account switch or destructive security test was performed during this audit.

## 4. Open security issue register

### SEC-01 — Business staff can directly change reward-grant status

**Severity:** High  
**Status:** Confirmed against effective production policy  
**Launch gate:** Blocking

Production still has an authenticated `grants_update` policy whose `USING` expression is only `app.is_salon_member(business_id)`. Authenticated users retain table UPDATE privilege. Snapshot guards protect reward economics but do not prevent a member from changing `status` to `redeemed` or `expired`.

**Impact:** An ordinary active member could suppress a customer's benefit and corrupt redemption and retention reporting. It is not presently a direct credit-theft path, but it is a server-side authorization and state-integrity failure.

**Root cause:** A legacy member-wide table mutation policy survived later reward hardening.

**Evidence:**

- `db/migrations/20260716084652_frenly_v2_saas.sql:140-143`
- `db/migrations/20260720_frenly_v27_rich_rewards.sql:490-498`
- `db/tests/v37b_versioned_retention_taxonomy.sql:202-211`
- Live policy: `grants_update`, `FOR UPDATE`, `USING app.is_salon_member(business_id)`

**Exact fix:**

1. Drop the direct member-wide update policy.
2. Revoke INSERT, UPDATE, DELETE and TRUNCATE on `reward_grants` from browser roles.
3. Route redemption, expiry, reversal and correction through narrow server functions.
4. Enforce valid state transitions, business/customer scope, explicit module authorization, row locking, idempotency and immutable reward economics.
5. Pin the function `search_path`, revoke PUBLIC execution, and grant only the intended role.

**Required regression:** staff, pending staff, inactive staff, anonymous and foreign-tenant users fail; approved workflows succeed; invalid/replayed transitions fail; `has_table_privilege` proves browser roles cannot update directly.

### SEC-02 — Cross-tenant child references remain possible in several write paths

**Severity:** Medium-high  
**Status:** Confirmed structural weakness in the effective production schema  
**Launch gate:** Blocking before multi-tenant launch

v572 correctly added module-aware mutation policies, but several child records still use simple foreign keys. An authorized module writer who knows another tenant's UUID may be able to attach that foreign object to a local record.

| Table | Remaining integrity gap |
|---|---|
| `service_products` | `service_id` and `product_id` are separate simple FKs; the policy scopes through the service but does not prove the product belongs to the same business. |
| `booking_requests` | Customer uses a composite business FK, but service, branch, staff and related references are not consistently composite with `business_id`. |
| `change_requests` | `appointment_id` is a simple FK and does not prove the appointment matches the request's business. |
| `waitlist` | `client_id`, `service_id` and table references are simple FKs. |
| `appointment_services` | Policy scopes through the appointment, but `service_id` is not proven to belong to that appointment's business. |

`service_branches` is not open: it now has composite service/business and branch/business FKs and owner-only production mutation policies.

**Exact fix:** add immutable `business_id` where absent, add `(id,business_id)` parent uniqueness, replace simple references with composite FKs, or use a same-business constraint trigger when a schema change is impractical. Complex writes should go through module-authorized RPCs.

**Required regression:** Businesses A and B; owners, authorized staff, module-disabled staff, pending/inactive staff and anonymous identities; attempt every A-to-B product/service/client/appointment/branch/staff attachment by known UUID and require a database rejection.

### SEC-03 — Superadmin MFA is available but not enforced

**Severity:** High defense gap  
**Status:** Confirmed application/server gap; no self-promotion exploit was found  
**Launch gate:** Blocking for platform console

The platform uses password sign-in and privileged RPCs verify superadmin membership, but they do not require an AAL2 session. Enabling TOTP in configuration does not force superadmins to enroll or challenge.

**Impact:** A stolen or recovered superadmin password/session could provide all-tenant access.

**Exact fix:** require MFA enrollment before superadmin activation; require AAL2 inside every privileged RPC and Edge Function; require recent reauthentication for finance, access grants, impersonation and destructive actions; alert on sign-in, recovery, factor reset and access changes; define dual-controlled emergency access.

**Required regression:** AAL1 superadmin rejected, AAL2 superadmin accepted, stale/non-superadmin sessions rejected at every server boundary.

### SEC-04 — Client telemetry can store token-bearing URLs

**Severity:** Medium  
**Status:** Confirmed source risk

`app/app.js:95-108` reports `location.href`. Invite, join, OAuth, recovery or redemption routes may contain bearer material in query strings or fragments.

**Exact fix:** report only origin and pathname; strip query and fragment; explicitly redact token-like parameter names before logging; clear token-bearing fragments before potentially failing route work.

### SEC-05 — Redemption-intent flooding lacks a strong per-customer ceiling

**Severity:** Medium availability risk  
**Status:** Confirmed design gap

Fresh idempotency UUIDs can create additional short-lived redemption intents. Existing idempotency is per supplied key and is not a customer quota.

**Exact fix:** cap open intents per identity/business, lock the identity/business scope before counting, add per-user/IP/business rate limits, expire stale intents in bounded batches, and alert on abnormal creation.

### SEC-06 — Legacy classic redemption remains callable

**Severity:** Low  
**Status:** Hardening issue

The UI no longer offers classic redemption but the intent RPC still accepts the legacy kind. Reject it at the server boundary or keep it only behind an explicit tested feature flag.

### SEC-07 — Live OAuth/recovery redirect allowlist verified

**Severity:** Closed after live verification

The repository contained legacy/Vercel candidates, but the later read-only Management API check found only `peekaa.asia`, `www.peekaa.asia`, `nestly.asia`, and `www.nestly.asia` HTTPS patterns in the live allowlist. No Vercel or Frenly hostname is live. The original conditional risk was not reproduced.

**Maintenance:** retain ownership monitoring, remove redundant duplicate `/*` and `/**` patterns where safe, and keep a config-drift assertion so retired hosts cannot return unnoticed.

### SEC-08 — CSP still permits `unsafe-inline`

**Severity:** Low-medium defense-in-depth

The current CSP permits inline scripts/styles and several third-party script origins. No concrete stored XSS was confirmed, but a future missed escaping path would have greater impact.

**Exact fix:** move to nonce/hash-based scripts, remove unused origins, require SRI for external scripts, collect CSP violation reports, and test hostile stored values in customer names, business names, notes, imports, URLs, filenames and SVG/media fields.

### SEC-09 — Privileged API allowlist and ACL minimization

**Severity:** Medium hardening after completed follow-up

The earlier Supabase security-advisor snapshot reported:

- 690 authenticated-callable `SECURITY DEFINER` functions;
- 15 anonymous-callable `SECURITY DEFINER` functions;
- three mutable function `search_path` warnings;
- 254 RLS-enabled objects with no policy, many of which may be deliberately private.

The current catalog follow-up found 718 unique callable functions: 717 for `authenticated`, 15 for `anon`, with a 14-function overlap. The completed body/helper-chain classification accepted 553 direct-auth functions, 146 delegated-auth functions, eight intentional public endpoints and four server/internal exposed helpers. It found no authorization bypass and no unresolved manual-review row. Seven functions retain unnecessary anonymous execute grants.

**Exact fix:** revoke the seven unnecessary anonymous grants, verify and remove browser execute from the four internal helpers where unused, put the anonymous demo writer behind gateway abuse controls, and keep the generated 718-function allowlist plus CI grant-drift check current.

Official remediation reference: https://supabase.com/docs/guides/database/database-linter

## 5. Historical security findings closed by production v572

Effective production policies show that v572 already replaced the earlier member-wide mutation policies for:

- `services`;
- `waitlist`;
- `service_branches`;
- `service_products`;
- `booking_requests`;
- `change_requests`;
- `appointment_services`.

These should not be reported as open role-bypass vulnerabilities. The remaining problem is cross-tenant reference integrity, plus direct reward-grant updates. The v572 regression should be extended to verify effective privileges, every mutation verb and foreign-tenant UUIDs.

## 6. How far the product is from launch

Functional breadth is not the limiting factor. Evidence-backed security and operations are. The product is close enough for a controlled internal or synthetic pilot after the P0 technical fixes, but it is not ready for an unrestricted multi-tenant public launch.

| Goal | Current state | Gap to close completely |
|---|---|---|
| Customer trust | Core identity/tenant contracts are strong | Runtime abuse, hostile input, token telemetry, OTP configuration and exact-release journey proof |
| Business authorization | v572 closes the earlier broad staff writes | Reward-grant mutation and cross-tenant references must fail structurally |
| Superadmin protection | Membership checks and non-writable admin table | Mandatory AAL2 at every privileged server boundary, recovery controls and alerts |
| Reliable background work | All 35 active jobs succeeded in the sample | Remove nonproductive polling, eliminate bursts, measure productive work and own retention |
| Reproducible release | Extensive migration/test machinery exists | Live v590-v592 and the manual v361 schedule must be reproducible from one frozen SHA; v593 is already reproducible |
| Capacity efficiency | Database is only about 142 MB | Resolve growth/bloat and concurrency before buying capacity |
| Launch evidence | Many local/static contracts pass | Repository gate currently has **0/17 P0 items with valid production evidence** |

The launch-readiness checker itself is valid: it reported no malformed manifest entries, but every P0 remains blocked because the required hash-pinned production evidence is absent. Some older descriptions may be stale relative to the live schema; that does not convert missing exact-release evidence into proof.

### 6.1 The 17 production evidence gates

| Gate | What must be demonstrated before public launch |
|---|---|
| Cutover parity | Frozen source SHA recreates the live catalog, functions, RLS, grants and cron schedule exactly. |
| Public abuse | Hostile-origin, rate-limit, Turnstile and payload-limit drill on deployed gateways. |
| Booking token | Token hashing, expiry, replay denial, scope and lifecycle on production-shaped data. |
| RLS and grants | Effective two-tenant role matrix plus browser table/function privilege allowlist. |
| Finance reversal | Concurrency-safe refund/reversal/idempotency and immutable ledger proof. |
| Reporting scale | Representative-volume query/load test and priority FK/index plan. |
| PDPA operations | Named owners plus rehearsed access, deletion, retention and incident workflows. |
| Auth/email | Exact deployed signup/login/recovery/MFA behavior and provider-abuse configuration. |
| Notifications | Real-device/provider delivery, retry, opt-out and alert evidence. |
| Payments/subscriptions | Live-mode Checkout/webhook/replay/reconciliation/entitlement proof. |
| Backup/rollback | Timed restore/PITR and application/database rollback rehearsal. |
| Observability | Alerts reach a named responder; caught worker failures and queue age are visible. |
| Singapore timezone | Two-clock/browser/server DST-independent SGT boundary drill. |
| Target runtime | Exact reviewed SHA deployed and its configuration inspected. |
| Test credentials | Launch test OTPs/accounts/secrets expired or rotated without weakening controls. |
| Post-cutover smoke | Customer, staff, owner and superadmin smoke plus monitoring window. |
| Release build | Immutable build identity and production evidence tied to the deployed SHA. |

## 7. Cron and disk root-cause analysis

### 7.1 What actually caused cron growth

Before v590, pg_cron retained every run forever. The scheduler had generated approximately 144,000 rows and was producing roughly 9,300 rows per day before three support workers were consolidated. The first v590 cleanup passes deleted approximately:

- 20,000 rows;
- 84,882 rows;
- 2,190 rows.

Current policy retains succeeded runs for seven days and failed runs for 90 days, deletes in bounded batches, and caps a normal run at 20,000 deletions. It is working and must be maintained.

Deleting rows did not shrink the 26 MB physical relation. PostgreSQL can reuse that space. To return it to the filesystem requires a maintenance operation such as a table rewrite; `VACUUM FULL` locks the table and should only run in an approved maintenance window. For a 26 MB relation, reclaiming the file is lower priority than stopping unnecessary run generation.

### 7.2 Burst scheduling

Nineteen jobs started in the same second on 926 sampled occasions, but that measured alignment rather than concurrency. Interval analysis found a peak of 15 simultaneous executions and only about 4.158 seconds above eight simultaneous executions across the observed week (0.000672% of wall time). This is hygiene, not a capacity or launch blocker.

Stagger modulo schedules during routine cleanup instead of putting every `*/5` or `*/10` worker on minute zero. Add advisory-lock overlap guards where duplicate execution threatens correctness, plus maximum runtime/backlog alerts.

### 7.3 Other growth and lag contributors

- `sv_automation_runs`: about 16,268 rows and 5 MB. Historical tender-release code wrote empty-run markers even though there are currently zero live stored-value businesses and zero reserved tenders. v591 stops new empty writes, but old records remain.
- `sales`: about 16 MB despite only about 197 live rows; almost all space is indexes. Two indexes are roughly 5.2 MB each. This indicates historical index bloat/churn and warrants a controlled reindex review rather than dropping correctness indexes blindly.
- `product_adoption_events_v100`: about 9.7 MB; its retention job should remain.
- `clients`: about 6.7 MB with very few live rows; inspect index bloat.
- `audit_log`, inbox operation tables, outbox/domain-event tables, shadow evaluations and webhook consumer markers need explicit retention ownership.
- PostgreSQL statistics show large cumulative temporary I/O since 15 July, but current `pg_stat_statements` attributes most visible temporary writes to dashboard/catalog inspection rather than active cron workers. Cumulative temporary bytes are I/O history, not current disk occupancy.
- The very large transaction setup count corresponds to PostgREST per-request `set_config` work. It should be correlated with API gateway request metrics before being labeled failed user transactions.

### 7.4 Performance advisor backlog

The live performance advisor reported 1,107 notices:

- 801 unindexed foreign keys;
- 182 multiple permissive-policy warnings;
- 113 unused-index notices;
- five RLS init-plan warnings;
- two duplicate-index warnings;
- three tables without a primary key;
- one absolute Auth connection-allocation notice.

Do not mechanically add or drop hundreds of indexes. Prioritize foreign keys used by high-volume deletes, customer joins, cron purges, booking flows and financial workflows; use query statistics and representative data. Remove only proven duplicate indexes. Supabase remediation: https://supabase.com/docs/guides/database/database-linter

## 8. Complete live cron register

All active jobs succeeded in the sampled period. “Effective” below means the scheduler ran successfully and the job still has a justified product role; pg_cron's `1 row` success message does not prove useful business work. Empty-queue observations were collected separately.

| ID | Job / schedule | Observed execution | Decision | Reason and required action |
|---:|---|---|---|---|
| 1 | `frenly-points-expiry` — daily | 7/7 succeeded; ~0.05s average | **Maintain** | Loyalty/ledger correctness. Keep daily and monitor affected rows. |
| 2 | `frenly-membership-renewals` — daily | 7/7; ~0.03s | **Maintain** | Active subscription renewal/credit lifecycle. |
| 3 | `frenly-expense-recurrences` — daily | 7/7; ~0.02s | **Maintain** | Financial recurrence. Alert on failure or duplicate creation. |
| 4 | `frenly-booking-expiry` — every minute | 10,080/10,080 in 7d; ~0.014s current average; zero stale rows at inspection | **Maintain and optimize** | Core hold release. Keep the SLA, index the expiry predicate, expose affected-row metrics, add overlap lock, and stagger from other minute jobs. |
| 5 | `frenly-studio-executor` — every 5m | 2,016/2,016; ~0.034s; zero backlog | **Maintain provisionally** | Core domain-event execution, but synthetic-era behavior remains. Add queue age/rows metrics and retention for domain execution records. |
| 6 | `frenly-outbox-sweep` — every 2m | 5,040/5,040; ~0.016s; zero due backlog; no outbox/capture activity in 30d | **Approve coordinated pause** | No source/Edge consumer reads the synthetic capture sink. Pause only after disabling or replacing any producer that could still enqueue `consumer='comms'`, so future rows are not stranded. |
| 7 | `frenly-referral-shadow` — daily | 7/7; ~0.03s | **Temporary maintain, then remove** | Shadow validation only. Define acceptance date and retention; unschedule after referral parity is accepted. |
| 8 | `frenly-sv-expiry` — daily | 7/7; ~0.02s | **Pause until stored value launches** | Zero live stored-value businesses. Preserve tested reactivation procedure. |
| 9 | `frenly-sv-tender-release` — every 3m | 3,360/3,360; ~0.026s; zero reserved tenders | **Pause until stored value launches** | Historical source of about 16k empty automation markers. v591 short-circuits new writes, but the job remains unnecessary while the feature is off. |
| 10 | `frenly-sv-reconciliation` — daily | 7/7; ~0.07s | **Pause until stored value launches** | Financially important once live, presently no live authority. |
| 11 | `nestly-v94-subscription-lifecycle-daily` — daily | 7/7; ~0.29s | **Maintain** | Active subscription lifecycle. |
| 12 | `nestly-v100-adoption-retention-daily` — daily | 7/7; ~0.08s | **Maintain** | Storage/privacy retention; table is currently a top-size relation. |
| 13 | `nestly-v122-promotion-alerts` — every 15m | 672/672; ~0.04s | **Maintain** | Live promotion workflow. Track alerts created rather than only success. |
| 14 | `nestly-v156-subscription-automation` — every 5m | 2,016/2,016; ~0.04s | **Maintain and monitor** | Billing reminders/documents. Add poison-item and backlog-age alerts. |
| 15 | `nestly-v175-account-open-retention-daily` — daily | 7/7; ~0.03s | **Maintain** | Privacy/retention requirement. |
| 16 | `nestly-v176-ai-firm-reports-daily` — daily | 7/7; ~0.04s | **Conditional maintain** | Keep only while scheduled reports are offered. Trigger only on due dates where practical. |
| 17 | `platform-subscription-revenue-v200` — daily | 7/7; ~0.20s | **Maintain** | Accounting-critical revenue recognition. |
| 18 | `nestly-v255-campaign-send-retention-daily` — daily | 7/7; ~0.02s | **Maintain** | Marketing retention control. |
| 19 | `nestly-v281-billing-event-redrive` — every 5m | 2,016/2,016; ~0.03s | **Maintain** | Stripe retry safety. Enforce attempt caps, dead-letter state and alerts. |
| 20 | `nestly-v282-customer-push-dispatch` — every 5m | 2,016/2,016; ~0.03s | **Conditional maintain** | Keep if push is configured; otherwise deactivate. Record provider outcome and queue age. |
| 21 | `nestly-v282-bottle-expiry-daily` — daily | 7/7; ~0.16s | **Maintain** | Bottle lifecycle and reminders. Feature-gate internally if no bar tenants. |
| 23 | `v310-google-content-retention` — daily | 7/7; ~0.03s | **Maintain** | Privacy/storage retention. Batch and index as prospect volume grows. |
| 24 | `frenly-programme-pot-migrations` — every 10m | 1,008/1,008; ~0.03s; zero pending/running rows | **Disable now** | Finite migration worker has completed all work. Reactivate only through a controlled pending-migration process. |
| 25 | `nestly-v361-bringback-issue-daily` — daily | 7/7; ~0.17s | **Maintain, but register in source** | Two bring-back grants exist. Production job was manually scheduled; migration contains only a scheduling comment, making it the source/live discrepancy. |
| 26 | `nestly-stamp-expiry` — daily | 10/10; ~0.10s | **Maintain** | Stamp-cycle correctness. |
| 27 | `nestly-stamp-reward-expiry` — daily | 7/7; ~0.07s | **Maintain** | Earned-reward expiry. |
| 28 | `nestly-v511-work-reopen` — every 10m | 497/497; ~0.05s; zero work rows | **Pause unless Work OS launches now** | No current work. Otherwise reduce to hourly and use due-work indexing. |
| 29 | `nestly-v513-onboarding-stall` — hourly at :07 | 80/80; ~0.05s | **Maintain** | Two payment-pending onboarding records exist. |
| 30 | `nestly-v528-whatsapp-webhook-retention` — daily | 3/3; ~0.01s | **Maintain** | Seven-day raw webhook privacy retention. |
| 44 | `nestly-v551-retention-dispatch` — every 5m | 719/719; ~0.05s; zero due queue | **Disable while flag is false** | `whatsapp_retention_sends=false`. Reactivate atomically with the feature. |
| 45 | `nestly-v551-retention-status-ingest` — every 5m | 719/719; ~0.05s | **Disable while flag is false** | Consolidate with opt-out/status worker when enabled. |
| 46 | `nestly-v551-retention-optout` — every 10m | 360/360; ~0.07s | **Disable while feature is wholly off; otherwise maintain** | Compliance-critical if any marketing sends exist. When enabled, run with status ingest in one isolated tick. |
| 47 | `peekaa-whatsapp-reminder-sweep` — every 30m | 89/89; ~0.08s | **Maintain** | WhatsApp appointment notifications are enabled. |
| 49 | `nestly-v590-cron-history-retention` — daily | 1/1 current scheduled run; ~1.1s | **Maintain and tune** | Keep. Consider success 2–7 days and failure 30 days after operational approval; export aggregate metrics before deletion. |
| 50 | `nestly-v592-support-tick` — every minute | 876/876; ~0.03s | **Maintain** | Correct consolidation of three minute workers. Alert on `SUPPORT_TICK_WORKER_ERROR`, because caught worker failures can leave the outer cron status as succeeded. |

### Retired jobs whose history remains temporarily

| Old ID | Former command | History rows | Decision |
|---:|---|---:|---|
| 32 | `support_route_inbound_v531(200)` | 3,183 | Correctly retired by v592; allow v590 to age out history. |
| 33 | `v536_run_support_dispatch()` | 3,129 | Correctly retired by v592. |
| 34 | `support_ingest_status_v535(200)` | 3,129 | Correctly retired by v592. |
| 48 | Incorrect `CALL app.purge_cron_run_history_v590()` | 1 failed row | Replaced by working SELECT job 49; retain failure temporarily for incident evidence. |

## 9. Streamlined target schedule

### Disable after approval

- `frenly-programme-pot-migrations` immediately: queue is complete.
- `nestly-v551-retention-dispatch`, status ingest and opt-out while the entire feature is disabled.
- stored-value expiry/release/reconciliation until stored value is enabled for a live business.
- Work OS reopen while the work table remains empty, unless imminent launch requires it.
- referral shadow after acceptance evidence is signed off.
- synthetic outbox sweep if production confirms no dependency.

### Consolidate

- Keep the v592 consolidated support tick; never restore the three retired workers.
- When WhatsApp retention is enabled, use one exception-isolated retention tick for dispatch/status/opt-out rather than three schedules.
- Consider a single exception-isolated daily retention tick for small bounded purge tasks, while keeping financial/accounting jobs independent.

### Stagger and protect

- Offset modulo schedules across minutes rather than aligning every worker at minute 0/5/10.
- Add `pg_try_advisory_xact_lock` or an equivalent lease to high-frequency workers.
- Set a documented SLA, owner, feature flag, max runtime, batch size, queue-age alarm, retention policy and disable condition for every job.

## 10. Cron effectiveness model

“Succeeded” is insufficient. Each worker should expose:

- rows scanned and affected;
- productive-work ratio;
- current queue depth and oldest-item age;
- p50/p95/p99 runtime;
- failures, retries and poison items;
- lock waits and skipped-overlap count;
- provider/network result for Edge Function or WhatsApp work;
- last productive run, not merely last successful run;
- estimated run-history and application-table bytes generated per day.

Define automatic alerts for repeated empty work where a feature is disabled, queue age beyond SLA, increasing runtime, history growth, and caught worker errors.

## 11. Upgrade decision

**Do not upgrade Supabase solely because of the current cron table or database size.**

The current database is about 142 MB. On the Free plan that is materially below the documented 500 MB database-size ceiling; on paid plans it is far below the included 8 GB disk. The scheduler itself is healthy and fast. First remove unnecessary polling, stop application-table growth, reconcile migrations, address index bloat, and observe CPU/IO/connection graphs under representative traffic.

Upgrade compute only if, after these fixes, the dashboard shows sustained CPU, memory, connection or IOPS saturation under real load. Upgrade disk only if the Compute and Disk page shows actual disk pressure after accounting for database, WAL and system space.

Official references:

- Supabase Cron: https://supabase.com/docs/guides/cron
- Inspecting and retaining cron runs: https://supabase.com/docs/guides/cron/quickstart
- Database versus disk size: https://supabase.com/docs/guides/platform/database-size
- Disk billing and included capacity: https://supabase.com/docs/guides/platform/manage-your-usage/disk-size
- Upgrade caveats, including pg_cron history: https://supabase.com/docs/guides/platform/upgrading

## 12. Ordered remediation plan

### Phase A — Security launch blockers

1. Close reward-grant direct updates.
2. Add same-business composite constraints.
3. Enforce superadmin AAL2/MFA server-side.
4. Redact telemetry URLs and rate-limit redemption intents.
5. Apply the completed SEC-09 ACL-hardening batch: seven anonymous revokes, four internal-helper caller checks, and public demo abuse controls.

### Phase B — Source/production convergence

1. Mirror v590-v592 production migrations into both migration trees and both order manifests using the real applied versions. Do not duplicate v593; it is already present in `origin/main` commit `c859fd9a`.
2. Register the v361 cron schedule in migration source.
3. Add a cron manifest test comparing names, commands and schedules with the intended release catalog.
4. Freeze one release SHA and materialize a disposable database from source.

### Phase C — Safe cron reduction

1. Capture before metrics and queue state.
2. Deactivate, rather than immediately delete, the approved obsolete jobs.
3. Observe at least one full SLA/retention window.
4. Unschedule only after dependent journeys pass.
5. Let v590 age out history or use an approved maintenance window for physical reclamation.

### Phase D — Performance and retention

1. Stop/retain `sv_automation_runs` according to audit requirements.
2. Add retention to outbox, capture, shadow, inbox and audit tables.
3. Review sales/client index bloat and the two confirmed duplicate indexes.
4. Prioritize indexes for high-frequency workers and cascade paths based on real query plans.
5. Stagger schedules and add overlap locks.

### Phase E — Acceptance

1. Run two-tenant authorization and foreign-reference tests.
2. Run customer, business and superadmin browser journeys.
3. Prove every cron's last productive run, not just success status.
4. Verify alert delivery, backup restore and rollback.
5. Run the repository launch gate until all required P0 controls have production evidence.

### Phase F — Controlled rollout

1. Start with synthetic/internal tenants, then a small named pilot cohort.
2. Define automatic rollback thresholds for authorization denials, payment mismatch, queue age, error rate, latency and disk growth.
3. Expand only after a full billing/retention cycle and an incident-response drill complete without unresolved high-severity findings.
4. Preserve the exact release evidence bundle and compare it after every migration or schedule change.

## 13. Blind spots most likely to surface after launch

These are not all confirmed vulnerabilities. They are the highest-value failure modes still lacking realistic runtime evidence:

1. **Authorization drift after migrations.** Source-text tests can stay green while effective grants or an older policy survive. Diff the live catalog after every migration and fail deployment on unexpected privilege expansion.
2. **Stored XSS and export injection.** Exercise every user-controlled name, note, service, translation, URL, import cell, filename and SVG/media field in customer, business and platform views. Escape HTML and CSV formula prefixes; serve uploads with safe content types and isolated origins.
3. **Account and SMS abuse.** Validate live provider throttles, CAPTCHA coverage, budget alerts, recovery enumeration resistance, session revocation and factor-reset monitoring.
4. **Cross-tenant UUID chaining.** A UUID leak that appears harmless becomes exploitable when a child FK accepts foreign ownership. Structural same-business constraints remove this class instead of relying on secrecy.
5. **Silent cron failure.** Exception-isolated umbrella jobs may show pg_cron success while a child worker fails. Alert on worker audit events, queue age and last productive run.
6. **Append-only operational growth.** `sv_automation_runs`, audit, inbox, outbox, captured message, domain execution, webhook and shadow tables need named retention owners and byte/day alarms.
7. **Webhook and job replay storms.** Test duplicate, delayed, out-of-order and poison messages with bounded retries and dead-letter alerting.
8. **Backup confidence.** A configured backup is not a recovery capability until a timed restore proves auth, storage, database, secrets and release compatibility.
9. **Load cliffs hidden by small data.** The 801 unindexed-FK warnings should be triaged with representative tenant volume, especially booking expiry, purges, reporting and cascades.
10. **Third-party or legacy-domain compromise.** Remove unused origins/callbacks and inventory ownership/renewal for every external domain, script, messaging provider and payment endpoint.

## 14. One step beyond competitors

Closing the findings produces a safe launch. The following controls turn that work into a durable competitive advantage:

- **Structural tenant isolation:** make cross-business relationships impossible through composite keys, then publish automated isolation evidence for every release.
- **Bank-grade privileged access:** phishing-resistant MFA/passkeys for platform admins, just-in-time elevation, recent-auth challenges, dual control for destructive actions and immediate session revocation.
- **Self-cleaning operations:** every cron has an owner, feature gate, useful-work ratio, byte budget, retention policy, overlap lock and automatic sunset condition.
- **Customer-visible trust:** expose a plain-language security/privacy centre with active sessions, consent history, data export/deletion status and reward/financial audit receipts.
- **Evidence-driven releases:** generate a signed release attestation containing build SHA, migration/cron manifests, advisor deltas, two-tenant test results, backup restore result and live smoke outcome.
- **Cost-aware reliability:** forecast storage and queue growth per active tenant and feature, allowing capacity upgrades to be triggered by measured headroom rather than surprise or fear.

## 15. Definition of done

The gap is closed when:

- no browser role can directly corrupt reward state;
- cross-tenant references are rejected structurally;
- privileged platform calls require AAL2;
- source recreates the effective production migration and cron catalog exactly;
- only feature-backed cron jobs are active;
- every job has productivity, backlog, failure and growth metrics;
- cron and application retention are enforced;
- no unexplained same-second scheduler burst exceeds the chosen concurrency budget;
- production disk/CPU/IO observations show headroom without an unnecessary upgrade;
- the exact deployed SHA passes the launch security and operational evidence gates.
