# Nestly v93 production-readiness evidence

Status: local/rehearsal phase complete; production release not performed.

Candidate workspace:

- Worktree: `/tmp/nestly-e2e-acceptance.T2KRnz`
- Branch: `codex/synthetic-e2e-acceptance`
- Base production commit inspected: `7e47cd997ef3`
- Disposable Supabase branch: `wtegnefsgnyxhflzizcu`
- Production data, migrations, secrets, deployment, Git history and `main`:
  unchanged

## Gap found and closed locally

The v89 merchant QR scan did not carry the active till branch into the
canonical reward writer. Firm-wide owners could redeem, but correctly scoped
front-desk staff were refused.

v93 adds `merchant_scan_redemption_qr_v93(business, branch, token, key)`.
It requires an active branch visible to the authenticated staff member,
preserves replay locking, delegates catalog rewards to
`redeem_reward_at_context`, and records branch provenance. Quick Earn sends
the same server-filtered branch already used for sales. The branchless v89
scanner is explicitly revoked from `public`, `anon`, and `authenticated`, so
browser callers cannot downgrade around the v93 checks.

The dedicated Customers search also now recognizes phone-shaped input and
matches normalized digits against `clients.phone_norm`, so a stored formatted
number such as `+65 8123 4567` is found by either `+65 8123 4567` or
`81234567`.

## Real database campaign

The deterministic fixture created, inside one rollback-only transaction:

- one structurally synthetic business and two branches;
- owner, manager and front-desk staff;
- two customers with independent verified QR joins;
- two services;
- two products and two stock batches;
- a published points programme and manual-item reward;
- a sale, corrected replacement, appointment and redemption intent.

Verified outcomes:

- SGD25 sale credited 25 points and appeared in Customer A history;
- correction to SGD28 produced immutable reversal/replacement evidence and a
  net 28-point balance;
- customer appointment view returned the firm appointment;
- presenting the reward QR changed no value;
- Customer B, an outsider and an unassigned-branch front desk were denied;
- authenticated front desk could not call the legacy branchless v89 scanner,
  the pending intent stayed pending, and no redemption row was created;
- assigned front desk completed exactly one 20-point redemption;
- final customer balance was 8 and customer history showed the redemption;
- replay produced no second redemption or value effect;
- canonical eligibility evidence retained the selected branch;
- transaction rollback left zero business/customer/financial fixture rows.

An earlier standalone rehearsal Auth account was resolved by exact ID and
email, removed from the disposable branch, and the final synthetic Auth
residue count was zero.

Post-campaign catalog evidence on the disposable branch confirmed:

- `authenticated` execute on the legacy v89 scanner: `false`;
- `authenticated` execute on the branch-scoped v93 scanner: `true`;
- synthetic business residue: `0`;
- synthetic Auth residue: `0`.

## Automated evidence

- Production-config repository validation: 827 passed, 0 failed.
- Static release build: passed for all six public HTML artifacts.
- Migration manifest and canonical byte-order checks: passed.
- Writer-surface discovery/registry checks: passed.
- Read-only 390px Chromium check of the deployed kopi tiam public booking
  route: service/team/time/details journey rendered; it did not remain on the
  loading skeleton. The only console rejection was an optional Cloudflare
  analytics beacon blocked by the existing CSP; booking data and controls
  loaded.
- Rehearsal SQL suites passed:
  - v51 sale lines;
  - v59 cart, service/product and inventory hardening;
  - v83 customer intelligence;
  - v84 fast sale correction;
  - v87 overdue appointment amendment;
  - v88 platform onboarding;
  - v91 customer game notifications;
  - v92 synthetic reporting isolation;
  - v93 deterministic end-to-end campaign.

## Still outside this evidence

This phase does not claim:

- that v92/v93 or the candidate UI are deployed to production;
- a physical iPhone/Android passkey, camera, PWA-install or push-notification
  acceptance pass;
- delivery-provider acceptance for Web Push;
- live Stripe billing or customer card payments;
- synthetic stored-value top-up/spend/split-tender in production, which the
  current authority rules deliberately refuse.

Those require a separately approved release and owner/device acceptance
window after independent Sol acceptance.
