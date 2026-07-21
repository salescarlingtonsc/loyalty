# Frenly v36-v41 Remediation Contract

Date: 2026-07-20 (Asia/Singapore)
Status: v36-v40 IMPLEMENTED LOCALLY; v41 RUNTIME ACCEPTANCE BLOCKED
Production target: `gadpooereceldfpfxsod` (Singapore)

This contract closes the gaps found in the v25-v35 final review. It does not
authorize a production migration, deployment, feature enablement, commit, or push.

## Release sequence

| Version | Scope | Independent? | Required predecessor |
|---|---|---:|---|
| v36 | Safe draft reward eligibility reads and editor correction | No | v26-v27 |
| v37 | Versioned retention rules and branch override editor API | No | v26-v29, v36 |
| v38 | Customer personas, identity start, and relationship-claim journey | No | v30-v31 |
| v39 | Detailed, capability-filtered customer wallet | No | v32, v38 |
| v40 | Staff reversal workflows and reversal history | No | v20-v22, v34 |
| v41 | Runtime gates, complete regression suites, and browser acceptance | No | v36-v40 |

Each version must pass a rolled-back behavioral chain test before it can be accepted.
Static source-pattern checks are supplementary and cannot close a behavior gate.

## v36 - Draft reward eligibility

### Required behavior

The owner must be able to read and edit eligibility belonging to one draft without
receiving eligibility from the active or any historical configuration. A staff member
may continue to read the published projection needed at the counter. No customer role
receives raw eligibility-table access.

### Database API

Add an authenticated owner-only RPC:

`get_loyalty_reward_draft(p_config_version uuid) -> jsonb`

The RPC must:

- derive the caller from `auth.uid()` and require `app.is_salon_owner(business_id)`;
- take `FOR SHARE` locks on the configuration header and business row so publication
  cannot race the editor snapshot;
- accept only `status = 'draft'`;
- return the program version, tier versions, reward versions, and eligibility IDs for
  that exact configuration version;
- return both `reward_id` (stable identity) and `reward_version_id` explicitly;
- return the current configuration `snapshot_hash` for optimistic concurrency;
- allowlist all output columns and omit internal costs from any future customer API;
- use a fixed safe `search_path`;
- revoke execute from `PUBLIC` and `anon`, grant only `authenticated`, and be added to
  both v21 authenticated RPC allowlists.

Do not widen the existing child-table RLS policy to every member and every historical
version. The owner editor RPC is the narrow draft-read boundary.

Ordinary member reads of `loyalty_reward_versions` must also be limited to the active
configuration. Draft and historical reward metadata is available only through this
owner RPC or the existing super-admin policy.

All eligibility subqueries must match `reward_version_id`, `reward_id`, and
`business_id`; matching only the stable reward ID is insufficient.

### Browser contract

- Draft mode loads the complete editor payload through the RPC.
- Live mode may continue to use the published compatibility projection.
- Eligibility state is keyed by stable `reward_id`, never by reward-version row `id`.
- Saving replaces eligibility for the exact `reward_version_id` in one transaction.
- Browser saves include `expected_snapshot_hash`. After locking the header,
  `save_loyalty_config_draft` rejects a stale hash with SQLSTATE `40001` and performs
  no child-row changes. A successful save returns the new hash.
- A failed read or save must leave the existing restrictions visible and the action
  retryable; it must never fall back to an empty unrestricted selection.
- Changing loyalty model must prompt before discarding unsaved changes or preserve the
  current draft values.
- Tier buttons must restore their enabled state and label after every failed RPC.

### Required tests

1. Owner reads one draft and receives only that version's eligibility.
2. Staff, unrelated owner, customer, anon, and `PUBLIC` are denied.
3. Active and draft versions with different branch/service/product restrictions never
   mix in the response.
4. Edit without changing eligibility preserves byte-equivalent restrictions.
5. An empty selection intentionally publishes unrestricted eligibility.
6. A read failure cannot submit an empty replacement.
7. Draft publish snapshots the exact eligibility tree and leaves the previous published
   version unchanged.
8. Two owner sessions using the same hash cannot overwrite each other: the first save
   succeeds and the second receives `40001` with every draft child row unchanged.
9. Concurrent draft read/save versus publish returns one complete version and never a
   mixture of program, reward, and eligibility rows.

## v37 - Retention and branch configuration

### Versioned retention rules

Add stable retention-program identities plus `retention_program_versions` rows scoped
to `firm_config_versions`. Version at least:

- name, active, goal visits, period days;
- reward taxonomy ID and immutable fulfillment projection;
- discount, credit, or manual-item parameters;
- sort and customer/staff description where applicable.

Backfill every existing live retention program into the business's current published
configuration without changing its behavior. Reward grants retain their existing
snapshots and source program identity. New and edited programs must use the same draft,
hash, publish, and supersession transaction as loyalty rules. Remove browser INSERT,
UPDATE, and DELETE privileges from the live `retention_programs` projection.

The sale/visit trigger must resolve retention rules from the sale's stamped immutable
configuration version. Publishing while a sale is recorded must serialize on the
business row and must not mix two versions.

### Branch override editor API

Add owner-only RPCs rather than exposing raw draft writes:

- `save_loyalty_branch_override_draft(p_version, p_branch, p_override jsonb)`
- `remove_loyalty_branch_override_draft(p_version, p_branch)`

Both must validate same-business ownership, draft status, the explicit field allowlist,
and values before changing a row. The loyalty editor must show a firm-default value and
an optional per-branch override side by side, with `Inherit firm setting` as the simple
default. Preview must resolve the same function used by earning.

### Reward taxonomy editing

Owners may rename, sort, and retire taxonomy labels. The machine fulfillment kind is
immutable; changing behavior creates a new taxonomy identity. Retired types remain in
history and cannot be selected by new drafts.

### Required tests

1. Existing live retention behavior backfills unchanged.
2. Direct live retention writes by browser roles are denied.
3. Draft edits do not affect visit processing until publish.
4. A sale concurrent with publish uses exactly one complete version.
5. Historical grants retain their taxonomy label and behavior after rename/retirement.
6. Branch default, override, removal, and cross-business denial pass.
7. Rollback-as-new-version restores prior retention and branch behavior without deleting
   history.

## v38 - Customer identity, claims, and personas

### Routes

Resolve these routes before staff onboarding:

| Route | Contract |
|---|---|
| `/#/claim` | Authenticated identity start and email/invitation claim |
| `/#/wallet` | Independently scoped business cards |
| `/#/wallet/{slug}` | One verified firm relationship |
| `/#/workspace/{slug}/{module}` | Active staff membership and module permission |
| `/#/b/{slug}` | Guest-first portal with optional signed-in context |

The public business route remains Turnstile and public-gateway controlled when signed
in. Authentication does not bypass booking policy, rate limits, or public field
allowlists.

### Persona resolver

Add `get_my_personas() -> jsonb` returning only:

- `staff[]`: business slug, business name, role, and effective modules;
- `customer[]`: business slug and business name for verified links;
- a safe default route.

It must not expose client IDs, contacts, notes, balances, or platform totals. The
persona switcher appears only when both arrays are non-empty. Switching changes route
context, never database privileges.

### Claim journeys

- `customer_create_identity` remains one immutable Auth-user mapping and creates no
  business relationship.
- Email claim uses the confirmed Auth email and exact normalized equality against
  exactly one unclaimed client in the requested firm.
- Outcomes are generic: `linked`, `no_link_created`, or `try_later`.
- Invitation tokens are opaque, expiring, one-use, stored hashed, removed from browser
  history immediately, and excluded from logs and telemetry.
- Unlink immediately removes wallet authority while retaining the client, transactions,
  claim evidence, and immutable unlink audit.
- Name and phone are never claim authority.

### Authentication gate

Customer email OTP remains disabled until production SMTP, sender authentication,
Turnstile, Auth rate limits, recovery, monitoring, and support ownership are accepted.
The completed UI may remain fail-closed, but normal enablement must use private
server-derived capabilities rather than three hard-coded frontend constants.

### Required tests

Cover identity creation, exact email claim, duplicate generic outcome, invitation
expiry/replay/theft denial, unlink, changed contact, dual role, customer-only and
staff-only principals, and strict cross-business isolation. All RPCs require fixed
search paths, authenticated-only grants, v21 allowlisting, idempotency where mutating,
and bounded abuse controls.

## v39 - Detailed customer wallet

Add customer-safe, cursor-bounded RPCs that derive the identity, link, business, and
client entirely from `auth.uid()` plus business slug:

- `customer_get_loyalty_details(slug, cursor)` for points/stamps activity, expiry,
  redemptions, and grants;
- `customer_get_reward_catalog(slug)` for customer name, description, image, terms,
  eligibility summary, and availability, excluding internal name and business cost;
- `customer_get_packages(slug, cursor)` for plan name, purchased and remaining sessions,
  status, expiry, and bounded usage history;
- `customer_get_memberships(slug)` for customer-visible plan and period state;
- the existing appointments and capability APIs, made cursor-aware where needed.

The UI displays only enabled, relevant, non-empty modules. Required sections are
Rewards, Activity, Packages, Membership, Appointments, and Book. Every section must
have loading, empty, denied, retryable-error, and mobile states. Do not show customer
self-redemption unless fulfillment, cancellation, and reversal are complete; otherwise
present the reward as a counter claim.

Tests must prove column allowlists, pagination bounds, module hiding, no cross-firm sum,
no raw-table customer access, and Customer A/B isolation for every RPC.

## v40 - Staff reversal workflows

Add permission-aware interfaces over the existing RPCs only. Never permit direct
browser writes to sales, ledgers, batches, package provenance, or redemption provenance.

- Sale detail calls `reverse_sale` with a required reason, stable idempotency key,
  explicit reference, and supported restock policy.
- A package-session reversal states that no payment refund occurs.
- Redemption detail calls `reverse_loyalty_redemption` and explains provenance,
  spent-credit, and impossible-balance rejection.
- Completed reversals disable the primary action; exact retry displays the completed
  result and a changed retry displays a conflict.
- Sales history, customer history, reports, and exports display reversal relationships
  and net values. Remove text claiming reversals are deferred.

Browser visibility must require the database permission and permitted branch scope.
Required tests cover owner/manager/authorized staff, inactive staff, restricted branch,
customer, anon, replay, conflict, package restoration, loyalty compensation, and exact
ledger/batch reconciliation.

## v41 - Acceptance and feature gates

Private server gates:

- `customer_identity`
- `customer_claims`
- `customer_wallet`
- `customer_actions`
- `customer_notifications`
- `customer_email_otp`

A disabled gate returns a generic unavailable state without disclosing identity, link,
client, or business existence. A build-time kill switch may remain only as an emergency
fail-closed control.

### Required database evidence

1. Restore the missing executable historical baseline or produce a reviewed immutable
   production-schema baseline.
2. Create a disposable production-equivalent database in Singapore.
3. Apply the complete migration chain once.
4. Execute all v20-v41 rollback suites, v21 all-schema ACL checks, RLS adversarial
   principals, and concurrency harnesses.
5. Prove no `SECURITY DEFINER` function is executable by anon or `PUBLIC`, and prove the
   explicit authenticated/service-role allowlists match the shipped call graph.
6. Reconcile points ledgers to FEFO batches and all sale/redemption/package reversals.

### Required browser evidence

1. New customer authenticates, creates an identity, claims an exact email relationship,
   and sees one firm card.
2. Invitation succeeds once; replay is safe; another user is denied.
3. A dual-role user switches wallet/workspace without privilege bleed.
4. Signed-in `/#/b/{slug}` booking remains Turnstile and public-policy controlled.
5. Wallet shows only relevant complete modules on desktop and mobile.
6. Customer requests cancel/reschedule and staff receives the immutable request.
7. Owner edits reward eligibility and branch overrides in a draft, previews, publishes,
   and rolls back as a new version.
8. Staff reverses a sale, package session, and loyalty redemption with correct replay and
   conflict behavior.
9. All customer gates disabled produce safe unavailable states.

## Acceptance rule

Sol may return PASS only when all v36-v41 behavior above is implemented and the database
and browser evidence is attached to the reviewed commit. `npm run validate` and
`git diff --check` remain mandatory, but cannot independently prove completion.
