# Frenly Part C - Configurability and Customer Architecture

## Status and scope

This is the single Part C design artifact. It replaces the incomplete
configurability draft and incorporates the Part C correction brief and both
independent audits. It is a design contract only. It authorizes no application,
database, test, Git, deployment, or production change.

Implementation of v25 through v34 remains blocked until this document receives
a reviewer PASS. Production remains gadpooereceldfpfxsod only. No push,
deployment, or production migration is authorized until the owner writes exactly
RELEASE APPROVED.

Frenly is a business-configurable engine. Templates and industry
recommendations are optional starting data, never platform rules. Financial,
loyalty, customer, and access behaviour is resolved from active configuration
and is never inferred from an industry label alone.

## Baseline and production aggregate inventory

The current deployed baseline is main at 8c5e4ab, with 45 migrations ending at
v24. The current product has a staff workspace, anonymous join, anonymous
booking, and opaque booking-management links. It does not yet have customer
identities, customer links, customer wallet routes, or customer-facing database
contracts.

The following is the approved aggregate inventory for migration planning. It is
a redacted production snapshot supplied for this design review; no production
query is run as part of this document change.

| Inventory item | Count |
|---|---:|
| Client records | 9 |
| Clients with usable email | 2 |
| Clients with usable phone | 8 |
| Potential duplicate email groups within a business | 0 |
| Potential duplicate phone groups within a business | 0 |
| Staff rows | 3 |
| Active staff rows with a login | 3 |
| Exact staff/client contact-match candidates | 0 |
| Booking requests | 5 |
| Booking-management tokens | 0 |
| Appointments | 7 |
| Points-ledger entries and points batches | 7 each |
| Loyalty redemptions | 0 |
| Reward grants | 1 |
| Client packages | 1 |

No customer identity is backfilled from a name, similar spelling, phone suffix,
or email similarity. Existing client rows remain unclaimed until a permitted
verification or invitation succeeds.

The dual-role candidate check compares staff and client rows only within the
same business, using exact case-normalized non-empty email equality or exact
`app.norm_phone()` equality. It found zero candidates. This is planning evidence,
not proof that no staff member is a customer: a dual-role relationship may use a
different verified contact and must still be created only through the normal
customer verification or invitation flow.

## 1. Customer access modes and route model

### Access-mode diagram

~~~mermaid
flowchart TD
  G[Guest] --> B[Direct business link /#/b/{slug}]
  B --> P[Public business information and availability]
  P --> GB[Guest booking through Turnstile-gated gateway]
  GB --> M[Opaque booking-management link]

  A[Authenticated auth.users identity] --> R[Resolve personas server-side]
  R --> C[Customer relationship exists]
  R --> S[Staff membership exists]
  C --> W[/#/wallet - My Frenly]
  W --> CB[/#/wallet/{business-slug}]
  S --> X[/#/workspace/{business-slug}/{module}]
  C --> Q[Claim an existing client relationship]
  Q --> V[Verified email match or firm invitation]
  V --> W
  S --> X
  A --> D[Persona switcher only when both personas exist]
~~~

### Route and interface contract

| Route | Caller | Purpose | Required server decision |
|---|---|---|---|
| /#/b/{slug} | Guest or signed-in visitor | Public firm page, availability, booking, private token entry | The gateway determines public visibility, booking enablement, and allowed public fields. A signed-in session does not bypass public controls. |
| /#/wallet | Authenticated customer | My Frenly business-card list | Resolve customer_identity from auth.uid() and return only verified, active customer_links. Never aggregate balances across firms. |
| /#/wallet/{business-slug} | Authenticated customer | One firm relationship and its relevant modules | Resolve the relationship from auth.uid() and slug on the server. The client may not select another business_id or client_id. |
| /#/claim | Authenticated customer | Claim an existing client record | Starts a verification or invitation flow. It does not reveal whether a candidate client exists. |
| /#/workspace/{business-slug}/{module} | Authenticated staff | Business workspace | Resolve an active staff membership and its module permission for the requested business. |

The direct business route remains guest-first. A firm may require login for
booking only through an explicit, published booking policy. That policy must be
returned by the public gateway; the browser must not infer it from a hidden
button or module list.

The persona switcher is shown only when get_my_personas() returns both an active
staff membership and a verified customer relationship. Switching changes
navigation context, not database privileges. Every request independently
derives the caller's effective staff or customer relationship from auth.uid().

### Dual staff/customer persona model

One auth.users account can be both a staff member of one or more businesses and
a customer of one or more businesses. These are independent relationships:

| Persona | Relationship source | Grants access to | Does not grant access to |
|---|---|---|---|
| Staff | Active staff.user_id equals auth.uid() for one business | Business workspace modules allowed by role and staff.modules | Any customer wallet, customer relationship, or another business |
| Customer | Verified customer_identity.auth_user_id equals auth.uid() plus customer_links | Only that person's linked client record for that business | Staff workspace, raw tenant tables, or another linked firm |
| Dual role | Both independent relationships exist | One selected route at a time | Union of staff and customer powers |

The server never trusts a browser-selected role. Staff RLS remains fail-closed.
Customer access is a separate policy class and must never reuse staff-membership
predicates.

## 2. Customer authentication and recovery dependency matrix

| Journey or release | Required identity method | SMTP dependency | Abuse and expiry controls | Release decision |
|---|---|---|---|---|
| Staff-only closed pilot | Existing staff password flow may remain, subject to the existing Auth gate | SMTP may remain deferred only where reset and confirmation limitations are formally accepted | Turnstile, Auth rate limits, password policy, leaked-password protection, redirect allowlist, monitoring | Customer wallet is not publicly live |
| Guest booking | No Frenly account by default | None | Turnstile, gateway origin control, privacy-preserving rate limit, opaque management token, idempotency key | Supported only when public-gateway evidence gates pass |
| Customer wallet release | Email OTP to a verified email address | Production-grade SMTP is compulsory before release | Turnstile before send and verify, per-identity and per-network rate limits, short OTP lifetime, one-time use, retry cap, cooldown, audit events, no OTP in logs | Blocked until SMTP and the customer-auth smoke matrix pass |
| Future phone OTP | Selected SMS or WhatsApp provider | Not applicable to email SMTP, but provider and sender governance are mandatory | Equivalent rate, expiry, retry, consent, recovery, and abuse controls | Deferred; no phone-only customer claim in MVP |
| Relationship claim | Verified email equality or firm-issued invitation | Email delivery is required for emailed invitation or OTP | Generic responses, no account-or-client enumeration, expiring single-use proof, idempotency, audit | Included in wallet MVP once email OTP is ready |
| Lost email or changed phone | Authenticated recovery plus an approved support process | SMTP required for email recovery | Re-authentication, cooling period, old-contact notification where safe, staff cannot override by judgement alone | Must be rehearsed before wallet release |
| Unlink or account deletion | Authenticated, re-authenticated request and operator review path | Notifications depend on chosen channel | Idempotent request, audit, legal retention decision, session revocation | Must be documented and tested before wallet release |

Customer email OTP is not a cosmetic UI choice. It is a production dependency:
customer-wallet release is blocked until reliable SMTP, sender identity, delivery
monitoring, recovery, and synthetic mailbox evidence are complete. Phone OTP
remains deferred; a phone number alone is never a password, recovery factor, or
relationship-claim proof.

## 3. Customer identity and edge-case lifecycle

### Data model contract

customer_identities is a platform identity record with one immutable mapping to
one auth.users account. It has no business privilege. customer_links is the
verified, business-scoped relationship from an identity to one existing clients
row.

Supporting contact-verification records are permitted because claim and recovery
require proof, but they record a normalized, protected contact fingerprint and
verification evidence rather than treating a display name as identity. The
business-owned client contact remains the source being matched; customer-facing
RPCs do not expose it unless the caller is entitled to see their own approved
value.

Required link states are pending, verified, rejected, and unlinked. A partial
unique rule permits only one active verified identity for a client row. A
duplicate client record inside the same business is not auto-merged and is not
silently attached to the same wallet card.

### Edge-case rules

| Case | Required behaviour |
|---|---|
| Duplicate names or similar spelling | Never match or merge automatically. |
| Shared family phone | Phone is not sufficient proof. The claimant needs verified email or a firm invitation. The design must not leak the other family member's relationship. |
| Recycled phone | A prior phone match has no authority after contact change or unlinking. No claim may rely on a historical phone alone. |
| Changed email or phone | Use a re-authenticated, audited change flow with a new verification proof. Do not change the client record merely because the Auth profile changed. |
| Two client rows for one person in one firm | Return a non-enumerating resolution state; require an explicit business duplicate-resolution process that preserves ledgers and appointments. No automatic merge in MVP. |
| Staff user also a customer | Keep both relationships and make the user choose a route. Do not inherit the other persona's access. |
| Different verified contacts across firms | Each customer_link is independently verified; no cross-firm contact discovery or aggregation. |
| Unclaimed legacy clients | Remain staff-managed and invisible in My Frenly until a claim succeeds. |
| Incorrect claim attempt | Return a generic outcome, rate-limit, write an audit event, and disclose no client existence or contact value. |
| Unlink | End the active customer link, retain business transaction records and an immutable unlink audit, and revoke customer portal access immediately. |
| Account deletion | Disable or delete the Auth account only under the approved privacy process; preserve legally required business transactions, sever the identity link, revoke sessions, and retain the minimum audit evidence allowed by policy. |

## 4. Customer RPC and RLS security contract

Customer-facing functions are a distinct API family, named customer_* and
registered in the security suite. Security-definer functions are an
implementation tool, not the authorization model.

Every new authenticated customer RPC must be added to both enforced repository
allowlists: `v_authenticated_rpc_names` in
`db/migrations/20260719_frenly_v21_security_hardening.sql` and the matching list
in `db/tests/v21_security_hardening.sql`. The migration and standing test must
remain identical, and the post-migration runtime catalog assertions must pass.

Every customer-facing RPC or server operation must meet all of these conditions:

1. It requires an authenticated session unless explicitly designated as a public gateway operation.
2. It validates auth.uid() inside the operation and resolves exactly one customer identity.
3. It derives the business and client scope from a verified customer_link; an input business_id or client_id is advisory only and must match the derived relationship.
4. It returns only an explicit column allowlist. Staff notes, tags, internal contacts, audit detail, financial internals, and unlinked client rows are excluded by default.
5. It uses an explicit safe search_path, revokes PUBLIC and anon execute rights, and grants only the minimum authenticated execute right where required.
6. It uses a caller-supplied idempotency key for every state-changing action and stores an immutable request hash.
7. It applies rate limiting to claim, recovery, contact-change, token, and other abuse-prone operations.
8. It writes an audit record for claims, verification, unlinking, contact changes, sensitive reads where required, and customer-initiated booking changes.
9. It never enables raw authenticated SELECT on clients, ledgers, appointments, packages, memberships, rewards, or staff tables merely to make the portal convenient.

The public gateway family is limited to deliberately anonymous operations such
as public business read, guest join, guest booking, and opaque
booking-token management. Each such operation retains its separate Turnstile,
origin, rate-limit, and token contract.

### Required customer security tests

The security suite must inspect customer-facing functions in every application
schema, not only public, and must prove all of the following in rolled-back
tests:

| Test | Required result |
|---|---|
| Customer A requests Customer B's link, client, appointment, reward, package, or ledger data | Denied with no data disclosure |
| Customer substitutes another business_id or client_id | Denied because server-derived link scope does not match |
| Business A user probes Business B customer links | Denied; no relationship metadata is discoverable |
| Staff-only user invokes a customer RPC | Denied unless that Auth user independently has the requested verified customer link |
| Customer-only user invokes staff RPC or reads staff table data | Denied |
| Dual-role user changes route context | Only the route's independently derived relationship is effective; no union of roles |
| Anonymous or PUBLIC caller invokes customer RPC | Denied; grant inventory is clean |
| Raw table access through PostgREST | Denied to customer callers; only allowlisted RPC output is available |

## 5. Immutable configuration publication semantics

### Configuration lifecycle

Existing typed loyalty and retention structures remain the source of business
rules. They are not replaced by an untyped JSON rules engine. However, live rows
may no longer be edited in place once versioning begins.

firm_config_versions is the immutable header for a business configuration
version. Each version is draft, published, superseded, or abandoned, has a
monotonically increasing version number, an optional based_on_version_id, a
snapshot hash, actor, and audit timestamps. Typed child configuration rows carry
config_version_id.

Publication is a single transaction:

1. Lock the business configuration scope.
2. Validate the complete draft, including ownership of branches, services, products, and reward types.
3. Reject missing required configuration and invalid cross-row combinations.
4. Mark the previous published version superseded.
5. Mark the draft published and atomically move the business active-version pointer.
6. Write an immutable publication audit containing the prior and new version IDs and snapshot hashes.

All financial or loyalty-consuming paths resolve the active version once at the
beginning of their transaction, then stamp that config_version_id on the sale,
points ledger, points batch, reward grant or redemption, package or membership
effect, and any relevant reversal child. A later publication therefore changes
only future events.

Rollback is publication of a new draft cloned from a prior immutable version,
not an update of historical rows and not a mutation of the prior version. A
version may not be deleted once published or consumed.

### Configurable loyalty and reward model

The active typed configuration supports firm-selected loyalty models: classic,
points_tiers, and stamps. It also supports firm-selected earning basis such as
spend, visit, or appointment_completed, subject to the event contract for each
basis. Recommendations are copied into a firm draft; they never bind the firm
to a platform preset.

Reward fields include internal and customer-facing names, description, immutable
machine fulfilment kind, optional firm-visible taxonomy label, estimated cost,
instructions, terms, image, usage limit, and explicit expiry semantics. A
customer-facing reward type may not create a novel financial behaviour merely
because a firm changes its label. Financial fulfilment kinds remain a controlled
set with a tested ledger path.

Branch and service eligibility is relational, not uuid arrays. Versioned
eligibility tables reference the reward version and a branch, service, or
product belonging to the same business. NULL means all is represented by the
absence of restrictive eligibility rows, not by an unvalidated array.
Redemption snapshots the resolved reward version and eligibility decision.

valid_days is never used ambiguously. Catalog publication availability, customer
reward entitlement expiry, and points-batch expiry are separate fields with
separate event semantics. A free item, percentage discount, or custom reward
stays out of the customer MVP unless its fulfilment, tender, cancellation, and
reversal contracts are implemented end to end. No placeholder reward action is
shown.

after_redemption equals reset_card is deferred unless implemented as a
same-transaction, append-only forfeiture or compensation event with a clear
customer-visible explanation. It must never delete points batches or rewrite the
ledger.

## 6. Append-only reversal and ledger correction model

public.reverse_sale remains the sole parent reversal workflow. No parallel
refund or customer reversal engine is introduced. It continues to own
authorization, immutable idempotency reservation, atomicity,
financial-operation audit, and reversal result.

Every additional effect is an append-only child linked to the same reversal
operation, the original event, and the reversal sale. Original sales, package
uses, points entries, reward claims, and referral events remain immutable and
visible in history.

| Original effect | Compensating effect inside reverse_sale | Safe failure rule |
|---|---|---|
| Loyalty earning from the original sale | Linked negative points-ledger entry and linked batch reduction, preserving per-source provenance | Reject atomically when the original earned amount is no longer available to reverse without a negative or unprovable balance |
| Available reward grant | Linked reward-grant invalidation event | Reject atomically if the grant was redeemed, transferred, expired into another terminal state, or otherwise consumed |
| Reward redemption | Linked redemption-reversal event and only the necessary ledger compensation | Reject atomically if fulfilment was already consumed and cannot be reversed without an impossible balance or duplicate customer benefit |
| Package session usage | Linked session-restoration ledger entry, not an in-place session counter update | Reject atomically if the package is expired, the source cannot be proven, or restoring would exceed a valid balance cap |
| Package purchase | Linked package-sale compensation only when no dependent session use makes the remaining balance impossible | Reject atomically if any later usage prevents a non-negative, provable balance |
| Referral reward | Linked referral-reversal event and compensating credit entry where eligible | Do not clear qualification fields or rewrite the original referral history |

An already reversed sale returns the original completed result only for the
identical idempotency request. A different request for the same sale is
rejected. A later appointment that consumes a previously restored package
balance is a valid later event; a replay of the original reversal cannot restore
the session a second time. Partial refunds and unsupported provider settlements
remain explicitly rejected until separately designed and tested.

The current policy that disables points clawback and rewrites referral status is
not the Part C target. v34 replaces only the affected behaviour through the
existing parent workflow and append-only linked records. Existing historical
rows are not rewritten; legacy records without sufficient provenance remain
explicitly unsupported for this new compensation path.

## 7. Relevant-module visibility rules

The wallet receives one server-derived customer_portal_capabilities result per
verified business link. The browser may render only modules and actions declared
by that result. Capability calculation uses the verified link, business public
settings, active configuration version, enabled modules, relevant customer data,
appointment policy, and current permission state.

| Customer module or action | Show only when | Do not show when |
|---|---|---|
| Home | A verified relationship exists | The relationship is pending, rejected, or unlinked |
| Book | The business has published online booking and the caller may book | Online booking is disabled or a login-required policy is unsatisfied |
| Rewards and loyalty activity | An active programme is relevant and the customer has a visible balance, grant, reward, or activity | The firm has no enabled programme or no customer-relevant data |
| Packages | The firm enables packages and the link has a current or historical package the customer may view | Packages are disabled or no relevant package exists |
| Memberships | The firm enables memberships and the link has a visible membership | No membership exists or is visible |
| Appointments | The customer has visible upcoming or historical appointments, or a complete booking action is allowed | There is no appointment path or customer permission |
| Booking management | The caller holds a valid scoped token or an entitled authenticated appointment relationship | A phone number alone is supplied |

No empty module tabs, coming-soon controls, inaccessible actions, or
non-functional buttons are permitted. Each visible action must have loading,
success, empty, error, denied, and mobile states. An empty state belongs within
a relevant module only when it leads to a complete permitted journey; it is not
justification to expose an irrelevant tab. Advanced controls are progressively
disclosed after the primary customer action.

## 8. Detailed v25-v34 migration plan

Every migration must be inspected against the live schema before it is authored.
No migration may drop and recreate a pre-existing object unless ownership and
data impact have been independently proven. Each rehearsal runs in one BEGIN
through ROLLBACK chain, followed by npm run validate and git diff --check before
any release consideration.

Known baseline exception: v23d contains the historical
`drop table if exists public.loyalty_programs cascade` recovery migration after
the earlier loyalty-table incident. Production subsequently reached the
reconciled v23g/v24 state, but that destructive statement is not an approved
pattern or precedent. Before v25 is authored, rehearsal evidence must inventory
the current table, dependent objects, grants, policies, row counts, and loyalty
aggregates and confirm that the v23d-v24 recovery left no missing data or
dependency. No future migration may repeat that drop/recreate approach.

The current production baseline audit is recorded in
`docs/design/evidence/v23d-v24-loyalty-reconciliation.json`, SHA-256
`3a1c4fbf6c7ec5d0507298c3f287fc1afc961e6cc1a621d7bae3d35964f365f0`.
It confirms all v23-v24 migrations are present; the three loyalty tables exist
with RLS and three policies each; 3 programmes, 1 reward, and 0 tiers have no
orphan or duplicate-program anomalies; all nine dependent functions are
inventoried; and points-ledger total 345 equals remaining batches 345 with zero
per-client mismatches. The evidence also records the broad Supabase table ACLs,
which remain constrained by RLS and the standing security suite. This proves the
reconciled current baseline only; it does not approve the historical destructive
migration pattern.

| Migration | Existing tables affected | New tables, functions, or constraints | Backfill and existing-row behaviour | Null and duplicate handling | RLS and function grants | Rollback method | Rehearsal tests | Production impact | Safe independently? |
|---|---|---|---|---|---|---|---|---|---|
| v25 - onboarding loyalty draft | businesses, loyalty_programs, onboarding RPCs | program_templates; draft marker or inactive onboarding programme | Existing active programmes remain active and unchanged. New firm presets are seeded as drafts, never earning until published. | A missing template leaves an empty draft; no fallback active programme. Duplicate template slugs rejected. | Firms may read platform templates; only platform role writes them. Owners create and edit only their own drafts. | Revert new onboarding behaviour; preserve created drafts, never delete an active programme. | New-business draft does not earn; existing business still earns; cross-firm template access denied. | New firms require explicit publish before loyalty starts. | Yes, after current schema inspection. |
| v26 - immutable config versions | businesses, loyalty_programs, loyalty_rewards, loyalty_tiers, retention_programs, sale and ledger consumers | firm_config_versions, active-version pointer, versioned typed config rows, active-config resolver, publish and clone-rollback RPCs | Backfill every existing firm as immutable published v1. Future consumers stamp the resolved version ID; historical events retain prior snapshots. | No null active pointer for a firm with an active programme. Version number unique per business. Draft rows may coexist; only one published version per config scope. | Owners edit drafts and publish only their firm. Resolver is authenticated or internal only as required. Public and anon execute revoked. | Disable new draft creation and point only to the prior published version through a new audited publication; never delete consumed versions. | Atomic publish, rollback-as-new-version, concurrent sale versus publish, snapshot stability, RLS and ACL suite. | Future configuration editing changes from immediate mutation to draft/publish. | No. It must land before any versioned reward, taxonomy, or branch override migration. |
| v27 - rich rewards and relational eligibility | loyalty_rewards, loyalty_redemptions, reward grant paths, branches, services, products | Versioned reward fields; reward-branch, reward-service, and reward-product eligibility tables; redemption eligibility snapshot | Backfill current rewards as credit, customer name equal to current name, unrestricted eligibility, no per-reward entitlement expiry or usage cap. Existing redemptions remain immutable. | Absence of restrictive eligibility rows means all eligible. Eligibility rows must reference the same business as the reward. Reject duplicate eligibility rows and invalid cost or expiry. | Member reads remain staff-scoped. Customer reads use allowlisted RPCs only. Redemption functions require authenticated grant and deny public and anon. | Stop exposing new fields and publish a new version using the old supported credit reward shape; do not delete reward history. | Cross-branch and cross-service denial, cap, expiry, eligibility snapshot, credit redemption, and ACL tests. | New reward types remain hidden until their fulfilment contract is implemented. | No. Requires v26 active-version resolution. |
| v28 - firm reward-type taxonomy | retention_programs, versioned reward configuration | firm_reward_taxonomy with immutable machine fulfilment kind and firm label; resolver for retention reward type | Backfill each current fixed type to a firm taxonomy row and reference it from the active version. Existing reward events retain their original type snapshot. | Firm labels may duplicate only when explicitly allowed; machine fulfilment kinds are controlled and cannot be invented by a firm label. Retired types cannot be selected by new drafts. | Owners manage labels within their business. Only internal or authenticated, allowlisted resolvers execute. | Publish a new version referencing the prior taxonomy; do not change historical event type. | Taxonomy isolation, retired type rejection, fulfilment-kind allowlist, historical snapshot tests. | Removes fixed UI taxonomy without allowing arbitrary financial actions. | No. Requires v26 and v27 fulfilment vocabulary. |
| v29 - branch overrides and custom customer fields | Versioned loyalty config, branches, clients | Versioned branch override rows; typed client_field_definitions and client_field_values with data classification | No value is invented for existing clients. Existing firm-wide settings are represented as no override. Existing client columns remain unchanged. | Field value must match a firm-owned definition and typed validation. Duplicate field keys rejected per business. Sensitive fields require classification and are excluded from customer RPC allowlists by default. | Owner writes definitions and overrides; staff permissions are explicit. Customer may read or update only approved self-service fields through dedicated RPCs. | Retire a field or override prospectively; retain historical values where policy requires. Do not drop client columns or values. | Branch precedence, branch ownership, field validation, sensitive-field denial, customer self-service boundary tests. | Adds optional data collection; PDPA notice and retention operation must exist before use. | No. Requires v26 version scope. |
| v30 - customer identity and verified contacts | auth.users, clients, staff read-only relationship check | customer_identities, protected contact-verification evidence, identity audit events | Create no identities from existing clients. Create an identity only after an authenticated customer starts an approved wallet flow. Existing staff rows are not changed. | One identity per Auth user. No name-based merge. Contact proofs expire; shared or recycled phones are never sufficient proof. | Customer identity tables expose no raw direct client access. Public and anon denied. Authenticated caller can create or read only its identity through dedicated RPCs. | Disable new identity creation prospectively; retain audit. Do not delete client, staff, Auth, or financial records. | Customer-only account, staff-only account, dual-role account, duplicate name, shared/recycled phone, contact-proof expiry tests. | Establishes identity without granting any business relationship. | Yes, after v21-style ACL inventory is extended. |
| v31 - links, claims, invitations, unlinking | clients, businesses, customer identities, audit records | customer_links, claim attempts, firm invitations, unlink events; claim, approve, unlink, and recovery RPCs | All legacy client records remain unclaimed. Links are created only after verified email equality or firm invitation proof. | One active verified identity per client row. Duplicate client candidates return a generic resolution state. Claim attempts never enumerate client records. | Customer RPCs derive business and client from the link. Staff approval is scoped to the staff business. Public and anon denied. | Mark link unlinked through an audited compensating state transition; do not erase claims or clients. | Claim success/failure, invite expiry, replay, dual role, unlink, cross-business isolation, no-enumeration tests. | Enables link creation but not yet wallet data exposure. | No. Requires v30. |
| v32 - wallet reads and capability resolver | clients, points and credit ledgers, batches, rewards, packages, memberships, appointments, businesses | customer_get_wallet, customer_get_business_summary, customer_get_appointments, customer_portal_capabilities allowlisted RPCs | No data backfill. Existing data becomes visible only through a verified link and only when capability rules permit. | No link means no result. Multiple links return separate business cards, never a cross-business balance. Missing optional modules are omitted. | All RPCs require authenticated, revoke public and anon, explicit safe search path, minimum grant, audit policy, and registry entry in security tests. Direct raw-table customer reads remain denied. | Revoke RPC grants and remove routes later; do not remove links or history. | Customer A/B, business substitution, raw-table denial, dual-role context, column allowlist, empty-capability tests. | Creates read surface; no customer write beyond existing public booking. | No. Requires v30 and v31. |
| v33 - customer actions and notification preferences | Appointment and booking-change records, customer links, consent records | Authenticated booking-action RPCs, customer action idempotency records, business-scoped notification preferences and audit | Existing guest booking and opaque-token management remain unchanged. No outbound message is promised until provider operations are approved. | Every action has a unique request key and immutable request hash. Marketing preference is separate from essential transactional status. Missing SMTP prevents customer-wallet email release. | Authenticated customer action requires verified link and appointment ownership. Guest routes retain separate token controls. Public and anon denied for customer actions. | Disable new customer actions prospectively; preserve request and audit records. | Appointment ownership, cancel/reschedule replay, notification opt-out, provider-failure no-duplicate, rate-limit tests. | Adds action requests, not unrestricted direct appointment mutation. | No. Requires v30-v32 and notification operating model. |
| v34 - reversal extension with compensating child events | reverse_sale, financial_operations, sales, points ledgers and batches, reward grants/redemptions, client packages, referrals | Linked package-session ledger, reward reversal or invalidation records, reversal-effect links, reverse_sale extension only | Existing history remains immutable. Existing package balance may receive a clearly marked legacy opening entry only when current balance is known; old events without provenance remain unsupported for automated compensation. | Reject reversal before side effects when a dependent reward is consumed, a package is expired, later use makes balance impossible, source provenance is missing, or the idempotency request differs. | Reversal remains staff-authorized and authenticated. New helpers are internal or authenticated-only with public and anon revoked. Customer cannot reverse a sale. | Publish a new function version or disable new supported effect types; no rollback deletes compensating records. | Original/replay/conflict reversal, points availability, package expiry and later use, reward consumed, referral append-only, ledger net and cross-tenant tests. | Extends financial correction only after a disposable-database concurrency rehearsal. | No. Requires v20/v21/v26-v27 contracts and full financial suite. |

## 9. Revised customer MVP scope

### Included only when complete

- Direct business portal and public business information.
- Guest booking with Turnstile and opaque booking-management links.
- Customer email OTP login after production SMTP is operational.
- Secure claim by verified email match or firm invitation; no phone-only claim.
- My Frenly as an array of independently scoped business cards.
- Per-firm loyalty and reward visibility.
- Package-session visibility, upcoming appointments, and complete booking,
  reschedule, and cancellation-request journeys where enabled.
- Business-specific notification preferences and only provider-backed customer
  promises.
- Strict cross-business isolation, customer-only RPCs, and dual-role switching.

### Explicitly deferred

- Public marketplace or cross-business reward discovery.
- Social features, family sharing, package transfers, and customer-to-customer
  transfer.
- Phone OTP until a provider and operating model are approved.
- Advanced membership self-management.
- Arbitrary reward fulfilment types that lack a financial and reversal contract.
- Dashboard customisation that does not complete an SME or customer workflow.

## 10. Customer release blockers crosswalk

The following gates remain BLOCKED. This document does not change the
launch-manifest status. `policy.p0ClosureStatus: VERIFIED_PRODUCTION` is policy
metadata defining the evidence threshold required to close a P0; it is not an
aggregate claim that the launch is verified. Every individual gate remains
`BLOCKED` until its own hash-pinned production evidence is accepted.

| Gate | Customer or Part C relevance | Closure owner and evidence |
|---|---|---|
| P0-CUTOVER-PARITY-001 | Customer identities, links, RPCs, functions, configuration, and Auth settings require final target parity | Release engineering; strict comparator and configuration attestation |
| P0-PUBLIC-ABUSE-002 | Guest join and booking remain public abuse surfaces | Application security; gateway, rate-limit, replay, and denied direct-RPC evidence |
| P0-BOOKING-TOKEN-003 | Guest booking management must remain opaque-token scoped | Application security; token expiry, replay, cross-booking, and phone-only denial evidence |
| P0-RLS-GRANTS-004 | Customer RLS is a new policy class and must not weaken staff isolation | Database security; multi-principal rolled-back adversarial suite and ACL inventory |
| P0-FINANCE-REVERSAL-005 | v34 cannot release without append-only reversal and reconciliation evidence | Financial systems; full reversal, rejection, retry, ledger, and role-denial evidence |
| P0-REPORTING-SCALE-006 | Version stamps and customer effects must reconcile through reports at SGT boundaries | Data engineering; pagination, reconciliation, and performance evidence |
| P0-PDPA-OPERATIONS-007 | Identity, claim, unlink, deletion, consent, and retention require rehearsed operations | Privacy operations; notices and synthetic data-subject rehearsal |
| P0-AUTH-EMAIL-008 | Customer email OTP and account recovery require SMTP and secure Auth settings | Identity engineering; production SMTP, mailbox, expiry, redirect, and anti-automation evidence |
| P0-NOTIFICATIONS-009 | Customer booking and wallet promises require a defined, observable provider model | Product operations; delivery, retry, opt-out, and failure evidence |
| P0-PAYMENTS-SUBSCRIPTIONS-010 | Reward fulfilment and customer claims must not overstate payment capability | Commercial systems; truthful manual or provider-backed operating model evidence |
| P0-BACKUP-ROLLBACK-011 | Identity and financial migrations require rehearsed restore and reconciliation-aware rollback | Platform operations; PITR, isolated restore, and rollback plan evidence |
| P0-OBSERVABILITY-012 | OTP, claims, public abuse, notification failure, and financial exceptions need named alert routes | Platform operations; redacted drill and alert-receipt evidence |
| P0-SGT-TIMEZONE-013 | Booking, expiry, reward validity, and scheduled jobs require SGT boundary proof | Application engineering; browser, database, report, and job test evidence |
| P0-TARGET-RUNTIME-014 | Customer portal must use only approved target URL, key, and CSP origins | Release engineering; served artifact and header evidence |
| P0-TEST-CREDENTIALS-015 | Customer and staff test identities or disclosed credentials cannot remain production-valid | Security operations; rotation and least-privilege attestation |
| P0-POST-CUTOVER-SMOKE-016 | Guest, customer, dual-role, staff, sale, loyalty, reversal, and denial journeys need final smoke evidence | Release engineering; synthetic smoke and monitoring-window report |
| P0-RELEASE-BUILD-017 | Portal, wallet, policy, authentication, and legal routes must build and deploy together | Release engineering; reviewed artifact, route allowlist, and header evidence |

## Acceptance criteria for reviewer PASS

This Part C artifact is ready for reviewer PASS only when all conditions below
are true. The review remains design-only until then.

1. The access-mode diagram, route contract, and dual-role model explicitly keep guest, customer, and staff access separate.
2. The authentication matrix states that production SMTP is mandatory for customer email OTP and documents recovery, contact change, unlinking, and future phone OTP.
3. Customer identity and link lifecycle rules cover every listed edge case without name-based or phone-only matching.
4. The customer RPC contract includes authentication, server-derived scope, allowlisted output, safe search path, grants, idempotency, rate limiting, audit, raw-table denial, and all required adversarial tests.
5. Config drafts, publication, rollback, active-version resolution, and event stamps are immutable and atomic.
6. Reward eligibility is relational and business-owned; expiry and fulfilment semantics are unambiguous.
7. Reversals use reverse_sale, append-only child records, atomic idempotency, and explicit impossible-balance rejection without historical rewrites.
8. The portal visibility decision table prevents empty, unauthorized, unfinished, and non-mobile-ready controls.
9. Every v25-v34 table row specifies affected objects, new objects, backfill, existing rows, null and duplicate handling, RLS/grants, rollback, rehearsal, production impact, and independent safety.
10. The revised MVP contains only complete end-to-end journeys, and all 17 launch blockers have named owners and closure evidence.

## Reviewer record

Design implementation remains blocked pending independent review of this
completed single artifact. A future reviewer must return PASS, CHANGES REQUIRED,
or BLOCKED and must not begin v25-v34 implementation as part of the review.
