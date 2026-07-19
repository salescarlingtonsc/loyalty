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
| Edge secrets | Rotate via `supabase secrets set`; `PUBLIC_GATEWAY_TOKEN_SECRET` rotation breaks in-flight booking-management tokens (see functions/README.md) |
| Frontend | The old app (git commit `bb7d497`) stays live on its existing deployment until cutover | No frontend has been cut over to the new gateway yet |

## The no-split-brain rule (most important)
Before the frontend cutover, rollback is trivial: **leave production traffic on the old app**
and discard/redeploy the target. **After** the new target has taken live writes, do **not**
point traffic back to the source without an approved data-reconciliation plan — doing so
loses the writes made against the target. Keep the source read-only; never dual-write.

## DB migration rollback (v18 → v21)
The launch migrations are additive/least-privilege. Reverse in strict LIFO order only if a
specific migration is implicated:
- **v21 (security hardening)** — re-granting revoked EXECUTE/privileges re-opens the anon
  surface v21 closed. Prefer forward-fix over reverting v21.
- **v20 (financial engine, 4201L)** — adds `sales.reversal_of` + `payments`/`cash_drawer_*`/
  `expenses` and rewrites the immutability guard, commission snapshot, and `sale_commission`.
  Reverting requires restoring the pre-v20 bodies of those objects; safest path is PITR to
  just before v20 rather than hand-reversing 4201 lines.
- **v19 (public gateway)** / **v18 (reporting)** — additive; drop the objects they created.
- For a full reset, restore the source `kyzovonwnscrzmkvocid` snapshot per
  `docs/supabase-sync/CLI_RUNBOOK.md` (final-restore path), then re-replay v18–v21.

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
The frontend has not been cut over. If a cutover is later reverted, redeploy the prior commit
to the git-connected `loyalty` Vercel project (`git revert`/redeploy), and confirm the served
HTML points only at `gadpooereceldfpfxsod` (or, on full rollback, the prior project) with the
expected CSP/security headers.

## Owner actions to close P0-BACKUP-ROLLBACK-011
1. Confirm PITR + retention on `gadpooereceldfpfxsod` (dashboard), record retention window + owner.
2. Rehearse a restore on an isolated Supabase branch.
3. Record this runbook's decision path as the approved no-split-brain rollback plan.
