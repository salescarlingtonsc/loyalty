# Nestly local release audit — 2026-07-28

## Verdict

The v95 local candidate is suitable for independent release review and an isolated
production rehearsal. It is **not yet approved for production**. The governed production
ledger remains `0/17 VERIFIED_PRODUCTION`, the live site still serves commit
`6226777e34c41ac1bc5f6ec10edd13332e17c929`, and production does not yet contain v92-v95.

This distinction is intentional:

- `LOCAL CLOSED` means the implementation and disposable-database evidence pass.
- `OPERATIONAL ACTION` means code cannot prove a provider, backup, alert, rotation, or
  production deployment actually works.
- `PRODUCTION EVIDENCE` means the exact reviewed release must be exercised on the real
  target and registered in `docs/launch/launch-blockers.json`.

## Owner-approved mock-pilot operating record

On 28 July 2026 the owner approved a pre-incorporation mock pilot with synthetic
firms, customers, transactions and provider test modes only:

- operating label: **Nestly — pre-incorporation pilot**;
- UEN and formal entity registration: **not yet available**;
- interim privacy, retention and incident role: **Founder**;
- monitored interim privacy and operational-alert mailbox:
  `nestly.asia@gmail.com`;
- formal DPO designation and PDPC registration: **pending owner action**;
- the current PDPC process accepts both ACRA-registered and non-ACRA entities,
  including direct registration for a non-ACRA entity, so incorporation is not
  recorded as a prerequisite;
- this record is not a formal DPO designation and does not authorize a public
  commercial launch, production migration, production deployment or real payment.

Before a public commercial launch, the owner must replace this temporary record
with the registered entity name/UEN, formal DPO designation and public contact,
approved retention schedule, incident escalation ownership and PDPC registration
evidence.

## Frozen-candidate evidence

| Check | Result |
|---|---|
| Canonical migration replay | `135/135 PASS` from an empty PostgreSQL 17 database, UTC |
| Rolled-back SQL suites | `94/94 PASS`; `businesses=0`, `auth.users=0` after the matrix |
| Isolated concurrency harnesses | `18/18 PASS`, one fresh cloned database per harness |
| Production-shape v67 splice parity | `PASS` through the coupled v68a/v68b lift |
| Node/static contracts | `859/859 PASS` |
| Static production build | `PASS` for all six deployable pages |
| Vercel runtime error clusters | None in the prior seven days |
| Supabase security advisor | No `ERROR` findings; INFO/WARN items are triaged, with exact RPC/RLS allowlist tests covering the shipped browser/API surface rather than claiming a one-to-one mapping of every advisor warning |
| 375px unauthenticated mobile inspection | Sign-in, create-account consent, legal links, recovery entry, and install UI render without horizontal clipping |

## Defects closed in this pass

1. **v93 could not replay on a clean chain.** Its notification-copy predecessor expected
   v46 values and ignored the v48 appointment-change copy. The migration and tests now
   preserve the authoritative v48 copy and apply the v91/v93 constraints deterministically.
2. **Super-admin onboarding snapshots could fail for untouched firms.**
   `attention_due` could evaluate to `NULL` and violate its `NOT NULL` snapshot column.
   The already-applied v88 bytes remain immutable; forward migration v94 fail-closes the
   snapshot column and frozen JSON payload to `false`.
3. **Twenty SQL suites tested superseded behavior.** Their fixtures now assert the final
   v75, v89, v90, v91, v92, and v93 authorization and legal contracts instead of weakening
   current controls.
4. **Inbox concurrency omitted the final appointment capability.** The disposable fixture
   now enables the capability explicitly; the production gate remains intact.
5. **Stored-value concurrency used a retired top-up RPC.** The harness now records a
   branch-scoped cash payment through `record_sv_topup_sale`, proves the payment record,
   and retains the retired-path refusal.
6. **Commission acceptance SQL did not compile.** Literal percentage signs in PL/pgSQL
   `RAISE` strings were replaced with unambiguous `RAISE USING MESSAGE`.
7. **Customer privacy and sign-in UX gaps.** Existing C42/v71/v80 contracts retain
   mandatory Terms/Privacy acceptance. v92 advances the Privacy manifest and records
   immutable, optional, separately revocable Nestly/selected-partner marketing evidence.
   Frontend/Auth code provides password sign-in without OTP, password recovery by OTP,
   and passkey enrollment/sign-in support.
8. **Customer notification constraints drifted.** v93 constrains the durable customer-safe
   inbox to the reviewed transactional/game copy without allowing arbitrary promotional
   text through that channel.
9. **Privacy evidence drifted after the push disclosure was added.** Full validation caught
   a byte-digest mismatch between the published Privacy Notice and the pending v92 legal
   manifest. The manifest, SQL acceptance fixtures, and immutable selected-partner
   marketing evidence now use the exact current notice digest.
10. **Basic web push was only a product promise.** v95 adds an explicit opt-in subscription
    flow, self-scoped register/unregister RPCs, private endpoint/key storage, event and
    delivery de-duplication, quiet-hour and topic checks, retry leases, terminal endpoint
    revocation, a service-only dispatcher, and a six-event service-worker allowlist. No
    permission prompt is issued without the customer pressing **Enable notifications**.
11. **Independent Web Push review found four P1 boundaries.** The corrected freeze accepts
    only reviewed Chrome, Firefox, and Safari push-service endpoint shapes at both the
    database and dispatcher; limits each identity to five active devices and twenty
    successful subscription operations per ten minutes under a per-identity lock; binds
    browser confirmation to the current authenticated user with an explicit shared-device
    reset; and rechecks event deadlines immediately before transport while bounding provider
    TTL to the remaining lifetime. The new simultaneous eight-registration harness proves
    exactly five active and three deterministically revoked subscriptions.

## Customer experience status

### Implemented locally

- New customer with no programme receives one primary quest: **Scan a loyalty QR**.
- A current business QR carries the invitation through account creation/sign-in and claims
  that business without a second scan.
- Existing customers first choose a business programme; points, credit, packages, rewards,
  bookings, history, and benefits remain isolated per business.
- The home screen has **Add programme**, which opens the business-QR scanner. Customers
  cannot search for and self-link a business.
- Customer redemption creates a pending QR. Points are not redeemed until the matching
  business scans and confirms it. Completion changes the QR to a success state and plays
  the reduced-motion-aware success cue.
- A newly observed earn shows `+N points/stamps earned`, a short rising tone, and a light
  haptic cue. It does not replay on the initial history load.
- Profile/passkeys live in the account menu; notifications use the bell rather than a
  permanent navigation tab.
- Business booking and QR-redemption controls are capability-gated per firm.

### In-app and basic web-push events implemented

| Event | Customer copy |
|---|---|
| Points/stamps expire within 3 days | “Points/Stamps expire within 3 days” |
| Points/stamps expire within 1 day | “Points/Stamps expire tomorrow” |
| Reward becomes redeemable | “Reward unlocked!” |
| One qualifying visit remains | “Quest almost complete” |
| Birthday benefit becomes available | “Birthday surprise unlocked” |
| Booking request is received | “Booking request received” |
| Appointment time changes | “Appointment time changed” |

These remain durable, consent-aware inbox facts. v95 can also project the six safe event
types (`value_expiry`, `reward_ready`, `visit_progress`, `birthday_benefit`,
`booking_request_received`, and `appointment_time_changed`) to an opted-in device. The
single `value_expiry` type produces the reviewed three-day and one-day copy above.
Promotion text is deliberately not accepted by this basic channel.

### Customer UX still requiring runtime proof

- Authenticated customer, owner, manager, front-desk, dual-role, platform-admin, and sales
  role journeys must run against the exact deployed candidate. Local Turnstile intentionally
  rejects `127.0.0.1`, and production currently serves the older commit.
- Face ID/Touch ID is a WebAuthn passkey ceremony controlled by the device. The installed
  app attempts it automatically after the security challenge is ready, but Nestly cannot
  bypass or suppress the device's biometric confirmation prompt.
- Real-device Safari/installed-PWA checks remain required for keyboard, safe-area,
  camera permission, passkey, background/resume, and redemption scanning.
- Web push requires the reviewed dispatcher function and migration to be deployed, a VAPID
  key pair and subject plus a dispatcher secret to be configured, a scheduler to invoke the
  dispatcher, and successful synthetic delivery on iPhone installed-PWA and desktop Chrome.
  The production runtime intentionally exposes no VAPID public key yet, so it truthfully
  shows notifications as unavailable rather than claiming they are live.

## Production gate ledger

| Gate | Local/code status | What still prevents `VERIFIED_PRODUCTION` |
|---|---|---|
| P0-CUTOVER-PARITY-001 | Local canonical replay closed | Apply reviewed migrations to the intended target and capture exact catalog parity |
| P0-PUBLIC-ABUSE-002 | Static and SQL abuse controls closed | Run the hostile-origin/rate-limit drill on the real gateway |
| P0-BOOKING-TOKEN-003 | Token hashing, expiry, replay, and identity tests closed | Production token lifecycle drill |
| P0-RLS-GRANTS-004 | Exact allowlist and adversarial SQL closed | Production catalog/RLS evidence |
| P0-FINANCE-REVERSAL-005 | SQL, production-shape, and race harnesses closed | Rehearsal/production financial evidence |
| P0-REPORTING-SCALE-006 | Pagination and bounded-query contracts closed | Representative-volume load test; triage performance-advisor FK index backlog |
| P0-PDPA-OPERATIONS-007 | v92 legal/consent model closed | Name DPO/privacy owner, retention owner, incident owner; rehearse request/incident workflow |
| P0-AUTH-EMAIL-008 | Phone/password/recovery/passkey code closed | SMTP decision if email recovery/alerts ship; exact deployed auth drill |
| P0-NOTIFICATIONS-009 | Durable inbox and basic web-push implementation closed locally | Configure VAPID/dispatcher secrets, deploy the function, schedule delivery, and capture real-device delivery evidence |
| P0-PAYMENTS-SUBSCRIPTIONS-010 | Billing/Stripe projection contracts closed | Choose live Stripe vs manual launch model and prove payment/webhook reconciliation |
| P0-BACKUP-ROLLBACK-011 | Runbook exists | PITR/restore and rollback rehearsal |
| P0-OBSERVABILITY-012 | Runtime errors currently clean | Choose alert recipient and prove alert delivery/escalation |
| P0-SGT-TIMEZONE-013 | SGT contracts closed | Two-clock browser/runtime drill on exact release |
| P0-TARGET-RUNTIME-014 | Target config identified | Deploy and inspect the exact reviewed SHA |
| P0-TEST-CREDENTIALS-015 | Test seam is explicit | Remove/expire launch test OTPs and rotate launch credentials |
| P0-POST-CUTOVER-SMOKE-016 | Scripted only | Always runs last after deployment; complete monitoring window |
| P0-RELEASE-BUILD-017 | Local build closed | Commit/freeze exact tree, build that SHA, and register production evidence |

## Outbound notifications and premium promotions

The v95 candidate now contains the basic service-worker handler, private subscription
store, VAPID sender, and service-only outbound dispatcher. Therefore:

- Do not market OS push notifications as live until VAPID, scheduling, deployment, and
  real-device evidence are complete.
- Basic transactional push is limited to the six reviewed event types above, honors the
  current per-business topic preference and quiet hours, and records retry/de-duplication
  evidence without exposing endpoint material to browsers.
- Premium promotion campaigns should remain a super-admin-controlled entitlement. A firm
  drafts audience, offer, schedule, and budget; super admin approves; the system sends only
  to customers with the correct marketing consent; holdout/lift measurement uses the existing
  retention campaign engine.

Owner/runtime actions needed before basic web push can close:

1. Generate and securely configure the VAPID public/private keys and VAPID subject.
2. Configure a high-entropy dispatcher secret and deploy `customer-push-dispatch`.
3. Configure the production scheduler/monitor and choose the failed-delivery alert recipient.
4. Complete synthetic iPhone installed-PWA and desktop-Chrome delivery/revocation tests.

Email remains unselected and is not required for this web-push release. The commercial
model for premium campaigns (per send, monthly allowance, or module tier) remains a product
decision and does not widen the basic transactional channel.

## Go-live conclusion

The implementation is materially stronger and the local database/application candidate is
green. Production launch is still a **HOLD**, not because the local suite is failing, but
because the exact candidate is not deployed and the external/operational gates above are
not evidenced. Sol must independently review this frozen tree and evidence before any
commit, push, migration, or deployment is authorized.
