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
