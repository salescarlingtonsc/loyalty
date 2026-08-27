# Tenant consistency gates

Two read-only production probes, wired as operational gates by
`scripts/ops/tenant-consistency-gate.mjs`. Both suites run entirely inside `begin; … rollback;`
against the linked production project (`gadpooereceldfpfxsod`); neither writes anything.

| command | suite | what it proves |
| --- | --- | --- |
| `npm run tenant-gate` | `db/tests/tenant_divergence_scan.sql` | **no live tenant is in a state a reader or writer can act on wrongly.** 15 checks over *every* business, comparing the programme spine, the live `loyalty_programs` row, the versioned config, and the readers that consume them. |
| `npm run certify-tenant` | `db/tests/tenant_lifecycle_certification.sql` | **a business signing up today can complete the whole journey the product promises** — 29 assertions walking one brand-new tenant through birth → points → sale → wallet → catalogue → stamps → completion → off → back on, calling the real RPCs in the real order. |
| `npm run tenant-gate:prove` | scanner + synthetic divergence | **the gate is not blind.** Re-runs the scanner with an injected divergence and asserts the gate would exit 1, then re-runs the untouched scanner and asserts production is unchanged. |

## When each MUST run

**`tenant-gate` — before AND after** applying any migration that touches loyalty, programme,
configuration, reward, welcome, birthday, or referral tables or functions, and after any
production backfill. Before, to know the baseline you inherited; after, to know you did not
widen it. It is the only check that sees *existing* tenants — the certification only sees a
tenant born inside its own transaction.

**`certify-tenant`** whenever code changes onboarding or tenant creation, loyalty, programme
switching, configuration publishing, rewards, points, stamps, birthday, welcome offers,
referrals, redemption, or the versioning functions. It is **not** required for changes outside
those areas (cosmetics, marketing pages, unrelated modules, tooling) — it costs a few seconds
but a green run there proves nothing new.

**`tenant-gate:prove`** whenever the scanner SQL itself is edited, and periodically, to confirm
the detection path still fires. It is a gate on the gate.

## Verdicts

`tenant-gate` exits **1** when any DETAIL row is `RUNTIME-DANGEROUS` and has no allowlist waiver.
`HISTORICAL-ONLY` rows (D10 stale drafts, D12 version-1 provenance) are counted and printed but
never block — nothing live can act on them. `certify-tenant` exits **1** on any row whose value
does not start with `OK`. Totals and per-check counts are read from the suites' own SUMMARY rows;
the script hardcodes no tenant count.

## The allowlist

`db/tests/tenant_divergence_allowlist.json` — an array of
`{check_id, business_id, reason, added}`. Every field is mandatory and non-empty; a missing
`reason` aborts the gate rather than silently waiving. A waiver matches **only** the exact
`(check_id, business_id)` pair — a *new* business tripping the same check still blocks, which is
the whole point. Entries that match nothing are reported as a note so stale waivers get pruned.

Adding an entry is a review event: it says "this divergence is deliberate platform state." Today
there is exactly one — D13 on Cubbly SPA, whose `platform_module_overrides_v94` row deliberately
forces the `support` module on for the WhatsApp Inbox pilot.

## Guarantees the certification preserves

1. **Born whole** — a new tenant needs no manual repair after creation.
2. **Points lifecycle** — earn rate, gift, publish, sale, ledger, wallet and catalogue all agree.
3. **Unrelated-publish inertness** — a birthday edit or a social-link save moves no loyalty state.
4. **Both switch directions** — points→stamps and stamps→points, through the same switchboard.
5. **Pot parking** — switching parks the old pot untouched instead of draining or merging it.
6. **Mint/redeem agreement** — a completed card offers a claimable gift, and redeeming mints it
   and closes the claim.
7. **OFF everywhere** — loyalty off is off in the business row, hero, wallet, catalogue and
   public presentation, with no reader disagreeing.
8. **No resurrection** — turning loyalty back on restores the card exactly as it was and revives
   nothing else.
9. **Two-path equivalence** — two different setup routes produce an identical live programme,
   spine, welcome offer, and member-facing answer.

## Reference canaries

Two permanent reference shapes exist in production for consistency verification:

- **Mature canary — Cubbly SPA** (`8492e8d6-8888-4383-ada0-7e1ed69f0caa`): created 2026-07-16,
  carries the platform's full historical accretion (superseded versions, disarmed drafts, the
  deliberate D13 pilot override). Its job: prove mature-tenant correctness does not depend on
  historical accidents.
- **Fresh canary — QA Fresh Canary** (`0967ca2a-d1dc-4cc4-a44c-7aace63816bf`, slug
  `qa-fresh-canary`): created 2026-08-28 AFTER the v564–v566 wave, through the real superadmin
  approval path (`platform_decide_business_application_v105`), with zero manual repair. Entirely
  synthetic data (owner/customer auth accounts are unloginable by design — empty password hash);
  born whole, points live at 1/dollar, one published gift, welcome offer on, one verified
  customer holding a 5-point balance from a real till sale, all readers agreeing. Its job: any
  future divergence between it and expected fresh-tenant behaviour is a regression, and it must
  never need a backfill to stay healthy.

Both are ordinary tenants to the scanner — no special-casing. If the fresh canary ever appears
in a RUNTIME-DANGEROUS scanner row, that is a released defect, not canary drift.
