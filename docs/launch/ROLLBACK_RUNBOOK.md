# Frenly Production Rollback Runbook

Target production project: **`gadpooereceldfpfxsod`** ("loyalty", ap-southeast-1 / Singapore).
Rollback baseline: source project **`kyzovonwnscrzmkvocid`** ("loyalty", ap-south-1) — the
pre-v18 snapshot, `ACTIVE_HEALTHY` and intact. Keep it read-only until the rollback window closes.

> This runbook covers the mechanical rollback. **Confirming PITR/backups is an owner action**
> in the Supabase dashboard (Project → Database → Backups) and is required to fully close
> gate `P0-BACKUP-ROLLBACK-011`. Physical PITR is the preferred restore mechanism for a paid
> project; the logical baseline below is the floor, not the ceiling.

## Restore points
| Layer | Restore point | Notes |
|---|---|---|
| Database | Source `kyzovonwnscrzmkvocid` (pre-v18) + Supabase PITR on the target | PITR gives point-in-time; the source is a coarse pre-launch floor |
| Edge Functions | Previous function versions (Supabase keeps version history); or delete to disable | Currently `public-join`, `public-booking`, `manage-booking` @ v-latest |
| Edge secrets | Rotate via `supabase secrets set`; `PUBLIC_GATEWAY_TOKEN_SECRET` rotation breaks in-flight booking-management tokens (see supabase/functions/README.md) |
| Frontend | Prior known-good production deployment of the git-connected `loyalty` Vercel project | Cutover to `gadpooereceldfpfxsod` completed 2026-07-19; roll back by promoting/redeploying the previous READY production deployment |

## The no-split-brain rule (most important)
The frontend cut over to the target on 2026-07-19, so the target has been taking live
writes since then. Do **not** point traffic back to the source without an approved
data-reconciliation plan — doing so loses the writes made against the target. Keep the
source read-only; never dual-write.

## DB migration rollback (v18 → current canonical chain)
The canonical chain now runs through v49b (see
`supabase/canonical-migration-order.manifest.json`; `npm run canonical-migrations:check`
verifies it). As of 2026-07-23 production has the chain applied through v48, with
v49/v49a/v49b pending `RELEASE APPROVED`. Migrations are additive/least-privilege; reverse
in strict LIFO order only if a specific migration is implicated, and prefer PITR to just
before the implicated migration over hand-reversal. The highest-risk reversals:
- **v21 (security hardening)** — re-granting revoked EXECUTE/privileges re-opens the anon
  surface v21 closed. Prefer forward-fix over reverting v21.
- **v20 (financial engine, 4201L)** — adds `sales.reversal_of` + `payments`/`cash_drawer_*`/
  `expenses` and rewrites the immutability guard, commission snapshot, and `sale_commission`.
  Reverting requires restoring the pre-v20 bodies of those objects; safest path is PITR to
  just before v20 rather than hand-reversing 4201 lines.
- **v19 (public gateway)** / **v18 (reporting)** — additive; drop the objects they created.
- For a full reset, restore the source `kyzovonwnscrzmkvocid` snapshot per
  `docs/supabase-sync/CLI_RUNBOOK.md` (final-restore path), then re-replay the canonical
  chain in manifest order. Note the source snapshot is pre-v18 and predates all live
  target writes since the 2026-07-19 cutover — full reset therefore requires the owner's
  data-reconciliation decision first (see the no-split-brain rule).

## Edge Function rollback
```bash
# Disable the public gateway entirely (fail-closed for public traffic):
supabase functions delete public-join   --project-ref gadpooereceldfpfxsod
supabase functions delete public-booking --project-ref gadpooereceldfpfxsod
supabase functions delete manage-booking --project-ref gadpooereceldfpfxsod
```
Because v21 revoked the legacy anonymous join/booking RPC grants, deleting the functions
removes the public write path — only do this in tandem with reverting the frontend so public
pages are not left calling dead endpoints.

## Frontend rollback
The frontend cut over on 2026-07-19 and is served by the git-connected `loyalty` Vercel
project (`loyalty-pi-seven.vercel.app`). To roll back, redeploy the prior known-good
production deployment (`git revert` pushed through the approved release path, or promote
the previous READY deployment in the Vercel dashboard), and confirm the served HTML points
only at `gadpooereceldfpfxsod` with the expected CSP/security headers.

## Owner actions to close P0-BACKUP-ROLLBACK-011
1. Confirm PITR + retention on `gadpooereceldfpfxsod` (dashboard), record retention window + owner.
2. Rehearse a restore on an isolated Supabase branch.
3. Record this runbook's decision path as the approved no-split-brain rollback plan.

## 2026-08-22 rewards go-live wave (v423–v427)

All five are function/grant migrations plus two small data passes; none drops an object, so
each rolls back by re-issuing the captured predecessor bodies (quoted in each migration's own
header/regions and in the repo history) and dropping only what the wave created.

- **v423 (reward edit reaches customers)** — re-issue pre-v423 `business_update_reward_v326`
  (body in `20260816_nestly_v343_reward_edit_v326.sql`) and the pre-v423
  `app.reward_version_immutable_guard`. Version rows already synced by an edit stay — they are
  correct snapshots. Re-granting anon is never needed.
- **v424 (birthday window honoured)** — re-issue pre-v424 `customer_activate_birthday_benefit`
  (md5 d279ca7b0b4e211fc39ac5773d40a712); drop `business_save_birthday_program_v424(uuid,jsonb,text)`
  and `birthday_program_save_operations_v424` ONLY if the frontend calling it has been rolled
  back first. Entitlements written under v424 are correct and immutable — leave them.
- **v425 (referral explicit reward type)** — order matters: (1) re-issue the four captured
  pre-apply bodies (`app.on_sale_recorded`, `save_referral_program_v421`, `_v420`,
  `set_programmes_v314`); (2) only if no row holds `reward_kind='stamps'`, restore the
  `referral_programs_reward_kind_check` to `('points','voucher')`; (3) optionally
  `alter table public.referrals drop column blocked_reason` (inert if left);
  (4) drop `app.referral_payout_programme_v425(uuid,text)` last. Reverting re-opens the
  wrong-pot payout at any stamps-model tenant.
- **v426 (canonical tier resolver)** — re-issue the seven captured pre-image bodies; drop
  `app.tier_resolve_v426` and `app.conversion_tag_v426`. The `loyalty_programs.loyalty_model`
  backfill (2 rows: Cubbly, Hougang ABC) is data — pre-images are recorded in
  `db/tests/executed/v426_tier_resolver.sql`'s header if reversal is ever wanted.
- **v427 (entitlements reach customers)** — re-issue prior `customer_get_reward_history_v422`,
  `business_programme_usage_v271`/`_v386`, `business_set_welcome_offer_v215` from their own
  migrations; drop `customer_get_entitlements_v427(text)`. Roll the frontend back first if it
  has shipped the customer entitlement cards.

Frontend for the wave (nestly_v428/v429) rolls back by reverting the release commit through
the normal path — no storage or data coupling beyond the RPCs named above.

## 2026-08-22 staff redeem-now parity (v432)

Read-side only: one new internal core plus three re-issued list readers; no table, ledger or
redemption change. Rolls back by re-issuing the three captured pre-image bodies —
`staff_get_customer_actionable_loyalty_v145` (from `20260817_nestly_v381_balance_follows_live_programme.sql`),
`customer_get_reward_catalog` (pre-image in prod history / pre-apply capsule),
`customer_get_business_actions_v89` (pre-image in prod history / pre-apply capsule) — then
`drop function app.reward_availability_v432(uuid, uuid, timestamptz)` last (PL/pgSQL resolves at
run time: never drop the core while a reader still names it). Reverting re-opens the defect this
closed: the till offering gifts `app.redeem_reward_core` refuses (wrong-programme, past-card-end,
claimed-this-cycle). Frontend (grouping + per-reward units) rolls back by reverting the release
commit through the normal path.

## 2026-08-22 stamp lifecycle wave (v433–v436)

Order matters both ways. Applied v433 → v434 → v435 → v436; roll back in strict reverse.

- **v436 (earn pinning + lazy close)**: re-issue the v425 pre-image of `app.on_sale_recorded`
  (byte-captured in `db/migrations/20260822_nestly_v425_referral_explicit_reward_type.sql` §3).
  Reverting re-opens rule 6: sales stamp open cards at the newest published rate.
- **v435 (stamp cycle expiry)**: re-issue the pre-images of `app.redeem_reward_core` (v416 body),
  `app.reward_availability_v432` (v432 file §1), `public.customer_get_stamp_card_v323` (v416
  file), `public.publish_loyalty_config` (v434 §1), `public.create_loyalty_config_draft` (prod
  pre-image), and `public.business_set_earning_rule_v359` — the 6-arg overload must be DROPPED
  and the 5-arg re-created, never left side by side (PGRST203). THEN
  `select cron.unschedule('nestly-stamp-expiry')` and drop the four `app.*_v435` helpers, in
  caller-first order (sweep driver → per-business worker → closer → deadline). Do NOT drop the
  `stamp_validity_days` columns or narrow the `stamp_cycles` constraints while any
  `origin='expired'` row exists — history rows are the customer's record; leave schema in place.
- **v434 (publish guard on draft model)**: re-issue the v431 pre-image of
  `public.publish_loyalty_config` (v431 file) and the pre-image of
  `public.save_loyalty_reward_draft` (prod pre-image / pre-apply capsule). Reverting re-opens the
  blocked wizard switch (stamps→points publish refusal).
- **v433 (edit version split)**: re-issue the pre-images of `business_update_reward_v326`,
  `business_create_reward_v326`, `business_set_stamp_card_length_v414` (all in the v423/v414
  files), `app.loyalty_version_immutable_guard` (pre-v433 body, no token carve-out), then drop
  `app.stamp_config_edit_begin_v433` / `app.stamp_config_edit_commit_v433` /
  `app.stamp_open_card_risk_v433` last. Reverting re-opens the P0: a mid-cycle stamp edit
  rewrites the customer's open card in place. Version rows minted by the split path are ordinary
  published `firm_config_versions` and stay.

## 2026-08-22 history unit + wallet expiry rule (v437)

Read-side only: two re-issued readers, no schema or write-path change. Rolls back by re-issuing
the two captured pre-image bodies — `public.customer_get_transaction_history_v81` (pre-image in
prod history / this migration's header describes the only delta: the per-item `loyalty_unit` key
and unit-aware standalone descriptions) and `app.c45_base_actionable_wallet_card` (nestly_v426
body; delta is the `expiry.days` key). Reverting re-opens rule 13's defect: after a programme
switch the customer's Activity relabels historical stamp rows as points, and the points "?"
explainer loses its server-fed expiry rule.
