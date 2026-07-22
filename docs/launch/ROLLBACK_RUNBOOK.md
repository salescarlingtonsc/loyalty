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
