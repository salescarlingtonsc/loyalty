# V320 — spendable credit leaves the app

Date: 2026-08-14
Branch: `codex/v320-remove-spendable-credit`
Base: `main` @ `ccd3ce8` (V319)
Requirement: `CREDIT-REMOVAL-320`
Migration: **none.** No table, view, RPC, policy or trigger is added, altered or dropped. The
`credit_ledger` and `client_credit_balance` are untouched; every balance still exists in the
database and every historical entry is still readable by SQL.

## What the owner asked for

Owner, 2026-08-14, overruling V319's hide-at-zero rule: **"i do not want spendable credits to
exist in the app."**

V319 had removed the Spendable credit row only when the figure was zero, on the reading that a
real balance is a fact the counter must not miss. I raised that as a concern; the owner
reaffirmed. This ships their decision in full for every **display** surface.

## What shipped

Spendable credit had exactly two display surfaces in the app. Both are gone — removed, not gated
harder, and with no smaller replacement anywhere:

| Surface | Before | After |
| --- | --- | --- |
| Business → customer profile, summary card | `Spendable credit  SGD 15.00` row (V319: shown only when non-zero) | row deleted at every value, for every role |
| Business → customer profile, *Balance and earning* | `Spendable credit: SGD 15.00` line (added by V319) | line deleted |
| Customer wallet, secondary metrics | `Store credit  SGD 15.00` tile (shown when > 0) | tile deleted; the row now holds packages and membership only |

Supporting changes:

- `const cred` is deleted, because nothing renders it any more. `showCreditMetric` likewise. The
  undeclared-identifier sweep is clean (`1005 versioned references, all declared`) — this repo has
  shipped a crash before by deleting a declaration and leaving a reference.
- The staff-scope note read *"Points, rewards and spendable credit are business-wide customer
  balances."* It now reads *"Points and rewards are business-wide customer balances."* — the
  sentence must not promise a figure the page will not show.
- The reads are deliberately **not** removed: `staff_get_customer_actionable_loyalty_v145` and
  `customer_get_wallet` still return `credit_balance_cents`. Nothing renders it. That keeps this
  change a one-file revert if the owner wants any of it back.

## ⚠ What this does NOT do, and what the owner still has to decide

**Removing the display does not stop credit being created.** Four mechanisms still write to
`credit_ledger`, and three of them are live in production right now:

| Writer | Live in production? |
| --- | --- |
| Membership period credit (`membership_credit`) | **yes** — SGD 400.00 outstanding at AhXiang, last movement 2026-08-06 |
| Referral payout (`referral_reward`) | **yes** — 3 enabled referral programmes pay credit |
| Gift-card redemption (`gift_card_load`) | yes (QA Test Cafe holds a balance from one) |
| Reward with `fulfillment_kind='credit'` | configured by **0** businesses |
| `classic` loyalty model ("points become store credit automatically") | **8 programmes, 2 active** |

Production totals at the time of this change (read-only query against `gadpooereceldfpfxsod`):

```
ledger_rows                     5
clients_with_nonzero_balance    3
total_positive_cents          52300   (SGD 523.00)
```

Broken down:

| Business | Balance | Source |
| --- | --- | --- |
| AhXiang | SGD 400.00 | membership period credit: Flawless |
| QA Test Cafe | SGD 120.00 | gift card + membership + referral |
| ZZ-SYNTHETIC PS1B1 UAT Journey | SGD 3.00 | referral qualified |

Also relevant: **nothing in the app currently lets a customer spend this.** The stored-value till
path is refused at launch (`'Stored value is not available for launch.'`). So before this change
the balance was visible but unspendable; after it, it is neither.

**The open decision is what referral and membership payouts should pay instead.** Referrals are
one of the four independent programmes shipped in W5/W6, and today their reward *is* credit —
the customer profile still reads "Refer a friend — SGD 5.00 credit after their qualifying first
visit." Turning that off without a replacement removes the referral incentive; leaving it on
means credit keeps accruing where nobody can see it. That is a product call, not an
implementation detail, so it is **not** included here.

Not changed on purpose: the *Erase customer data* copy still reads "Sales, points, credit and
appointments stay for your accounting", because that sentence is about what the database retains
on erasure, and it remains true.

## Verification

`npm test` — **2958 / 2959**. The single failure is the known environment-bound
`tests/mobile` store-readiness check (`missing dependency privacy manifest:
node_modules/@capacitor/ios/…`; these worktrees have no `node_modules`), reproduced identically on
an untouched `origin/main` worktree.

Suites retargeted, each with the reason in place:

- `v103-programme-clarity-ui` — the wallet metric row rule now covers the two metrics that remain,
  plus three absence pins so the credit tile cannot drift back.
- `v145-launch-freeze-audit` — the credit row's gate is replaced by absence assertions, and the
  staff-scope sentence follows the copy change.
- `v249-customer-360-layout` — V249's "demoted, never deleted" still holds for points (it moved to
  the programme row in V319); credit is asserted absent.

Both absence assertions **strip comments before matching**. Without that, the comment explaining
the removal satisfies the check that the thing was removed — the same trap that made V319's
titlebar assertion pass for the wrong reason.

Real browser: `verify-v296-programmes-batch-walkthrough.mjs` **PASS steps 1–8** against the real
production bundles. The refreshed `v319-customer-profile-*.png` captures show the summary card
with no Spendable credit row for a fixture customer who holds SGD 15.00 — i.e. the row is gone at
a non-zero value, which is precisely what V319 would have kept.
